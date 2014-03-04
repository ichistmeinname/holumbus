{-# LANGUAGE OverloadedStrings #-}

-- ------------------------------------------------------------

module Hayoo.Hunt.FctIndexerCore
where

import           Control.Applicative          ((<$>))
import           Control.DeepSeq
import           Control.Monad

import           Data.Binary                  (Binary)
import qualified Data.Binary                  as B
import qualified Data.IntMap.Strict           as IM
import qualified Data.List                    as L
import qualified Data.StringMap.Strict        as M
import qualified Data.Text                    as T
-- import qualified Data.Map.Strict              as SM
 
import           Hayoo.FunctionInfo
import           Hayoo.Hunt.ApiDocument
import           Hayoo.Hunt.IndexSchema
import           Hayoo.IndexTypes

import           Holumbus.Crawler
import           Holumbus.Crawler.IndexerCore

-- import           Hunt.Common.BasicTypes
-- import           Hunt.Index.Schema
import           Hunt.Interpreter.Command

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

toCommand :: FctIndexerState -> Command
toCommand (IndexerState _ (RDX ix))
    = Sequence . concatMap toCmd . M.toList $ ix
    where
      -- compute duplicates generated by reexports of functions
      dupMap
          = toDup ix

      toCmd (k, (cx, t, cu))
          = case lookupDup cu dupMap of
              Just uris@(uri : _uris1)                  -- re-exports found
                  | uri == k
                      -> insertCmd (apiDoc2 uris) -- TODO: modify module attr and add all uris
                  | otherwise
                      -> []
              _       -> insertCmd apiDoc1
          where
            insertCmd = (:[]) . Insert
            apiDoc    = toApiDoc $ (T.pack k, (cx, t, fmap FD cu))

            -- HACK: add the type attribute of the custom info record
            -- to a classifying context with name "type"
            apiDoc1   = insIndexMap c'type tp apiDoc
                        where
                          tp = T.pack $ maybe "" (drop 4 . show . fctType) cu

            apiDoc2 u = insDescrMap d'module ms $               -- add list of modules
                        insDescrMap d'uris   us $               -- add list of uris
                        apiDoc1
                        where
                          us = T.pack . show                 $ u
                          ms = T.pack . show . map toModName $ u
                              where
                                toModName :: String -> String
                                toModName u' = maybe "" id $
                                               do (_, _, cu') <- M.lookup u' ix
                                                  fd          <- cu'
                                                  return (moduleName fd)

lookupDup :: Maybe FunctionInfo -> IM.IntMap [URI] -> Maybe [URI]
lookupDup v m
    | not (isFct v) = Nothing
    | otherwise     = do h  <- fmap fiToHash v
                         us <- IM.lookup h m
                         if null us || null (tail us)
                            then mzero
                            else return (L.sort us)

toDup :: M.StringMap (RawDoc FunctionInfo) -> IM.IntMap [URI]
toDup ix
    = IM.fromListWith (++) . concatMap to . M.toList $ ix
    where
      to (k, (_cx, _t, v))
          | not (isFct v) = []
          | otherwise     = [(maybe 0 id . fmap fiToHash $ v, [k])]

isFct :: Maybe FunctionInfo -> Bool
isFct Nothing   = False
isFct (Just fd) = fctType fd == Fct'function

{-
-- | The hash function from URIs to DocIds
docToId :: URI -> DocId
docToId = DId.fromInteger . fromIntegral . asWord64 . hash64 . B.encode
-- -}
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
