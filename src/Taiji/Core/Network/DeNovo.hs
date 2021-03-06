-- | Infer network de novo from data
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Taiji.Core.Network.DeNovo
    ( createLinkage
    , createLinkage_
    , readNetwork
    , readNodesAndEdges
    , getTFBS
    , outputBindingEdges
    , outputCombinedEdges
    , outputNodes
    ) where

import Control.Arrow ((&&&), second)
import           Bio.Utils.Misc                    (readDouble)
import           Bio.Data.Experiment
import           Bio.Pipeline.Utils                (getPath, asDir)
import Control.Monad.State.Strict
import           Bio.Data.Bed
import           Conduit
import Data.Conduit.Internal (zipSinks)
import qualified Data.IntervalMap.Strict as IM
import           Control.Lens                      hiding (pre, to)
import qualified Data.Set as S
import           Control.Monad.Reader              (asks)
import qualified Data.ByteString.Char8             as B
import           Data.CaseInsensitive              (mk)
import Data.Ord (comparing)
import Data.Function (on)
import           Data.List
import qualified Data.HashMap.Strict                   as M
import           Data.Maybe                        (fromJust)
import qualified Data.Text                         as T
import IGraph
import           Scientific.Workflow               hiding (_data)

import Taiji.Core.Utils
import Taiji.Core.RegulatoryElement
import           Taiji.Types
import           Taiji.Constants (edge_weight_cutoff)

createLinkage :: ( ATACSeq S (File tag2 'Bed)         -- ^ TFBS
                 , File t1 'NarrowPeak  -- ^ promoter activity
                 , Maybe (File '[ChromosomeLoop] 'Bed)  -- ^ HiC loops
                 , Maybe (File '[] 'Tsv)          -- ^ Expression
                 )
              -> WorkflowConfig TaijiConfig
                    (ATACSeq S (File '[] 'Other, File '[] 'Other))
createLinkage (tfFl, peakFl, hicFl, expr) = do
    dir <- asks
        ((<> "/Network/" <> asDir (T.unpack grp)) . _taiji_output_dir)
        >>= getPath
    anno <- fromJust <$> asks _taiji_annotation
    let netEdges = dir ++ "/edges_combined.csv"
        netNodes = dir ++ "/nodes.csv"
        bindingEdges = dir ++ "/edges_binding.csv"
    liftIO $ do
        openSites <- readBed $ peakFl ^.location
        expr' <- case expr of
            Nothing -> return M.empty
            Just e -> readExpression 1 (B.pack $ T.unpack grp ) $ e^.location
        tfbs <- runResourceT $ runConduit $ streamBed (tfFl^.replicates._2.files.location) .|
            getTFBS (fromNarrowPeak openSites)
        promoters <- findActivePromoters openSites <$> readPromoters anno 

        let proc = loops .| findTargets tfbs promoters .|
                createLinkage_ (fmap (second exp) expr') .|
                zipSinks (outputCombinedEdges netEdges)
                (outputBindingEdges bindingEdges)
            loops = case hicFl of
                Nothing -> return ()
                Just fl -> read3DContact $ fl^.location
        runResourceT (execStateT (runConduit proc) S.empty) >>=
            outputNodes netNodes
    return $ tfFl & replicates.mapped.files .~
        ( emptyFile & location .~ netNodes
        , emptyFile & location .~ netEdges )
  where
    grp = tfFl^.groupName._Just
{-# INLINE createLinkage #-}

fromNarrowPeak :: [NarrowPeak] -> BEDTree PeakAffinity
fromNarrowPeak = bedToTree max . map f
  where
    f x = let c = x^.chromStart + fromJust (x^.npPeak)
              sc = toPeakAffinity $ fromJust $ x^.npPvalue
          in (asBed (x^.chrom) (c-50) (c+50) :: BED3, sc)

getTFBS :: Monad m
        => BEDTree PeakAffinity  -- ^ Potential regulatory regions and its affinity scores
        -> ConduitT BED o m (BEDTree [SiteInfo])
getTFBS peaks = concatMapC f .| sinkList >>=
    return . (fmap . fmap) nub' . bedToTree (++)
  where
    f site = case IM.elems (intersecting peaks site) of
        [] -> Nothing
        xs -> Just $ (bed, [SiteInfo (getTFName site) siteSc (maximum xs)])
      where
        bed = asBed (site^.chrom) (site^.chromStart) (site^.chromEnd) :: BED3
        siteSc = toSiteAffinity (fromJust $ site^.score)
    getTFName x = mk $ head $ B.split '+' $ x^.name._Just
    nub' = M.elems . M.fromListWith (\a b -> if g a > g b then a else b) .
        map (\x -> (_tf_name x, x))
      where
        g = getSiteAffinity . _site_affinity

createLinkage_ :: Monad m
               => M.HashMap GeneName (Double, Double)   -- ^ Gene expression
               -> ConduitT (GeneName, ([TFBS], [TFBS]))
                           NetEdge
                           (StateT (S.Set NetNode) m) ()
createLinkage_ expr = concatMapMC $ \(geneName, (ps, es)) -> do
    let edgeEnhancer = mkEdges geneName "enhancer" es
        edgePromoter = mkEdges geneName "promoter" ps
        (geneExpr, scaledGeneExpr) = M.lookupDefault (0.1, 1) geneName expr
        geneNode = NetNode { _node_name = geneName
                           , _node_weight = scaledGeneExpr
                           , _node_expression = Just geneExpr }
    modify' $ S.insert geneNode
    edgeCombined <- forM (groupEdgeByTF $ edgeEnhancer ++ edgePromoter) $ \xs -> do
        let (tfExpr, scaledTfExpr) = M.lookupDefault (0.1, 1) tfName expr
            tfNode = NetNode { _node_name = tfName
                             , _node_weight = scaledTfExpr
                             , _node_expression = Just tfExpr }
            tfName = _edge_from $ head xs
            wCombined = lp 2 $ map (_edge_binding_affinity . _edge_type) xs
        modify' $ S.insert tfNode
        return $ NetEdge { _edge_from = tfName
                         , _edge_to = geneName
                         , _edge_type = Combined (wCombined * sqrt tfExpr) }
    return $ edgePromoter ++ edgeEnhancer ++ edgeCombined
  where
    mkEdges geneName anno = filter
            ((>=edge_weight_cutoff) . _edge_binding_affinity . _edge_type) .
            map siteToEdge
      where
        siteToEdge site = NetEdge
            { _edge_from = _tf_name $ site^._data
            , _edge_to = geneName
            , _edge_type = Binding
                { _edge_binding_locus = convert site
                , _edge_binding_annotation = anno
                , _edge_binding_affinity = getEdgeWeight site } }
    groupEdgeByTF = groupBy ((==) `on` _edge_from) . sortBy (comparing _edge_from)
    getEdgeWeight x = sqrt $ siteSc * peakSc
      where
        siteSc = getSiteAffinity $ _site_affinity $ x^._data
        peakSc = getPeakAffinity $ _peak_affinity $ x^._data
{-# INLINE createLinkage_ #-}


--------------------------------------------------------------------------------
-- IO related functions
--------------------------------------------------------------------------------

-- | Save the edge information to files.
outputBindingEdges :: MonadResource m
                   => FilePath -> ConduitT NetEdge Void m ()
outputBindingEdges output = filterC isBinding .|
    (yield header >> mapC edgeToLine) .| unlinesAsciiC .| sinkFile output
  where
    header = ":START_ID,:END_ID,chr,start:int,end:int," <>
        "annotation,affinity,:TYPE"
    isBinding e = case _edge_type e of
        Binding{..} -> True
        _ -> False
{-# INLINE outputBindingEdges #-}

-- | Save the edge information to files.
outputCombinedEdges :: MonadResource m
                    => FilePath -> ConduitT NetEdge Void m ()
outputCombinedEdges output = filterC isCombined .|
    (yield header >> mapC edgeToLine) .| unlinesAsciiC .| sinkFile output
  where
    header = ":START_ID,:END_ID,weight,:TYPE"
    isCombined e = case _edge_type e of
        Combined _ -> True
        _ -> False
{-# INLINE outputCombinedEdges #-}

-- | Save the node information to a file.
outputNodes :: FilePath -> S.Set NetNode -> IO ()
outputNodes fl = B.writeFile fl . B.unlines . (nodeHeader:) .
    map nodeToLine . S.toList
  where
    nodeHeader = "geneName:ID,expression,expressionZScore"
{-# INLINE outputNodes #-}

-- | Build the network from files containing the information of nodes and edges.
readNetwork :: FilePath  -- ^ nodes
            -> FilePath  -- ^ edges
            -> IO (Graph 'D NetNode Double)
readNetwork nodeFl edgeFl = do
    nodeMap <- M.fromList . map ((_node_name &&& id) . nodeFromLine) .
        tail . B.lines <$> B.readFile nodeFl
    runResourceT $ fromLabeledEdges' edgeFl (toEdge nodeMap)
  where
    toEdge nodeMap fl = sourceFileBS fl .| linesUnboundedAsciiC .|
        (dropC 1 >> mapC f) 
      where
        f l = ( ( M.lookupDefault undefined (mk f2) nodeMap
                , M.lookupDefault undefined (mk f1) nodeMap )
              , readDouble f3 )
          where
            [f1,f2,f3,_] = B.split ',' l
{-# INLINE readNetwork #-}

-- | Read network files as nodes and edges
readNodesAndEdges :: FilePath   -- ^ nodes
                  -> FilePath   -- ^ edges
                  -> IO ([NetNode], [((GeneName, GeneName), Double)])
readNodesAndEdges nodeFl edgeFl = do
    nds <- map nodeFromLine . tail . B.lines <$> B.readFile nodeFl
    es <- map f . tail . B.lines <$> B.readFile edgeFl
    return (nds, es)
  where
    f l = ( ( mk f2, mk f1), readDouble f3 )
        where
        [f1,f2,f3,_] = B.split ',' l

