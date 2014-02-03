{-# LANGUAGE OverloadedStrings #-}

-- ------------------------------------------------------------

module Hayoo.Hayoo2.FctIndexerCore
where

import           Control.Applicative          ((<$>))
import           Control.DeepSeq

import           Data.Binary                  (Binary)
import qualified Data.Binary                  as B
import qualified Data.ByteString.Lazy         as LB
import qualified Data.StringMap.Strict        as M

import           Hayoo.FunctionInfo
import           Hayoo.Hayoo2.PostToServer
import           Hayoo.Hayoo2.RawCrawlerDoc
import           Hayoo.IndexTypes

import           Holumbus.Crawler
import           Holumbus.Crawler.IndexerCore

import           System.Directory
import           System.FilePath

import           Text.XML.HXT.Core

-- ------------------------------------------------------------

type FctCrawlerConfig   = IndexCrawlerConfig () RawDocIndex FunctionInfo
type FctCrawlerState    = IndexCrawlerState  () RawDocIndex FunctionInfo

type FctIndexerState    = IndexerState       () RawDocIndex FunctionInfo

newtype RawDocIndex a   = RDX (M.StringMap (RawDoc FunctionInfo))
                          deriving (Show)

instance NFData (RawDocIndex a)

instance Binary (RawDocIndex a) where
    put (RDX ix)        = B.put ix
    get                 = RDX <$> B.get

emptyFctState           :: FctIndexerState
emptyFctState           = emptyIndexerState () emptyRawDocIndex

emptyRawDocIndex        :: RawDocIndex a
emptyRawDocIndex        = RDX $ M.empty

insertRawDoc            :: URI -> RawDoc FunctionInfo -> RawDocIndex a -> RawDocIndex a
insertRawDoc uri rd (RDX ix)
                        = rnf rd `seq` (RDX $ M.insert uri rd ix)

-- ------------------------------------------------------------

unionHayooFctStatesM        :: FctIndexerState -> FctIndexerState -> IO FctIndexerState
unionHayooFctStatesM (IndexerState _ (RDX dt1)) (IndexerState _ (RDX dt2))
    = return $!
      IndexerState { ixs_index     = ()
                   , ixs_documents = RDX $ M.union dt1 dt2
                   }

insertHayooFctM :: (URI, RawDoc FunctionInfo) ->
                   FctIndexerState ->
                   IO FctIndexerState
insertHayooFctM (rawUri, rawDoc@(rawContexts, _rawTitle, _rawCustom))
                ixs@(IndexerState _ (RDX dt))
    | nullContexts
        = return ixs    -- no words found in document,
                        -- so there are no refs in index
                        -- and document is thrown away
    | otherwise
        = return $!
          IndexerState { ixs_index = ()
                       , ixs_documents = RDX $ M.insert rawUri rawDoc dt
                       }
    where
    nullContexts
        = and . map (null . snd) $ rawContexts


flushToFile :: String -> FctIndexerState -> IO ()
flushToFile pkgName fx
    = do createDirectoryIfMissing True dirPath
         flushTo (flushRawCrawlerDoc True (LB.writeFile filePath)) fx
      where
        dirPath  = "json"
        filePath = dirPath </> pkgName ++ ".js"

flushToServer :: String -> FctIndexerState -> IO ()
flushToServer url fx
    = flushTo (flushRawCrawlerDoc False flush) fx
    where
      flush bs
          = postToServer $ mkPostReq url "insert" bs

flushTo :: ([RawCrawlerDoc FunctionInfo] -> IO ()) -> FctIndexerState -> IO ()
flushTo flush (IndexerState _ (RDX ix))
    | M.null ix
        = return ()
    | otherwise
        = flush $ map RCD (M.toList ix)

-- ------------------------------------------------------------

-- the pkgIndex crawler configuration

indexCrawlerConfig :: SysConfig                                       -- ^ document read options
                      -> (URI -> Bool)                                -- ^ the filter for deciding, whether the URI shall be processed
                      -> Maybe (IOSArrow XmlTree String)              -- ^ the document href collection filter, default is 'Holumbus.Crawler.Html.getHtmlReferences'
                      -> Maybe (IOSArrow XmlTree XmlTree)             -- ^ the pre document filter, default is the this arrow
                      -> Maybe (IOSArrow XmlTree String)              -- ^ the filter for computing the document title, default is empty string
                      -> Maybe (IOSArrow XmlTree FunctionInfo)        -- ^ the filter for the cutomized doc info, default Nothing
                      -> [IndexContextConfig]                         -- ^ the configuration of the various index parts
                      -> FctCrawlerConfig                             -- ^ result is a crawler config

indexCrawlerConfig
    = indexCrawlerConfig' insertHayooFctM unionHayooFctStatesM

-- ------------------------------------------------------------