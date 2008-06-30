-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Build.Crawl
  Copyright  : Copyright (C) 2008 Sebastian M. Schlatt
  License    : MIT
  
  Maintainer : Sebastian M. Schlatt (sms@holumbus.org)
  Stability  : experimental
  Portability: portable
  Version    : 0.1
  
  Sample Configurations for Indexer Applications. This will later change to be
  the interface for configuring indexers by xml files.

-}

-- -----------------------------------------------------------------------------
{-# OPTIONS -fglasgow-exts #-}
-- -----------------------------------------------------------------------------

module Holumbus.Build.Config 
  (
  -- * Basic data types
    IndexerConfig(..)
  , ContextConfig(..)
  , CrawlerState(..)
  , Custom
  
  , initialCrawlerState
  , loadCrawlerState
  , saveCrawlerState
  
  , mergeIndexerConfigs
  , mergeIndexerConfigs'
  
  -- * Crawler configuration helpers
  , getReferencesByXPaths
  , crawlFilter
  , simpleCrawlFilter
  , standardReadDocumentAttributes
  
  -- * Tokenizing
  , parseWords
  , isWordChar
  )

where

import           Data.Binary
import           Data.Char
import           Data.List
import           Data.Maybe

import qualified Data.Map    as M
import qualified Data.Set    as S
import qualified Data.IntMap as IM


import           Holumbus.Index.Common
-- import           Holumbus.Index.Documents
import           Holumbus.Utility

import           Text.XML.HXT.Arrow
import           Text.Regex


type Custom a = IOSArrow XmlTree (Maybe a)


-- | Configuration for the indexer. 
data IndexerConfig 
  = IndexerConfig
    { ic_startPages     :: [URI]
    , ic_tmpPath        :: Maybe String   
    , ic_idxPath        :: String
    , ic_contextConfigs :: [ContextConfig]
    , ic_fCrawlFilter   :: URI -> Bool     -- will be passed to crawler, not needed for indexing
    , ic_readAttributes :: Attributes
--    , ic_fGetCustom     :: (Arrow a, Binary b) => a XmlTree b
    } 
   
-- | Configuration for a Context. It has a name with which it will be identified
--   as an index part. The preFilter is applied to the XmlTree that is generated
--   by the parser and before the "interesting" document parts are selected by
--   the XPath Expression. The Tokenize functions defines how a string found by
--   the XPath Expression will be split into a list of Words. Since stopwords
--   are identified by a function it is possible to define a list of words that
--   shall not be indexed or a function that excludes words because of the count
--   of characters or a combination of both.
data ContextConfig 
  = ContextConfig
    { cc_name           :: String
    , cc_preFilter      :: ArrowXml a => a XmlTree XmlTree
    , cc_XPath          :: String             -- multiple XPaths for one Context needed ???
    , cc_fTokenize      :: String -> [String]
    , cc_fIsStopWord    :: String -> Bool
    , cc_addToCache     :: Bool
    }   
    
-- | crawler state
data CrawlerState d a
    = CrawlerState
      { cs_toBeProcessed    :: S.Set URI
      , cs_wereProcessed    :: S.Set URI
      , cs_docHashes        :: M.Map String URI
      , cs_unusedDocIds     :: [DocId]        -- probably unneeded
      , cs_readAttributes   :: Attributes     -- passed to readDocument
      , cs_tempPath         :: Maybe String     
      , cs_fPreFilter       :: ArrowXml a' => a' XmlTree XmlTree  -- filter that is applied before
      , cs_fGetReferences   :: ArrowXml a' => a' XmlTree [URI]
      , cs_fCrawlFilter     :: (URI -> Bool)  -- decides if a link will be followed
      , cs_fGetCustom       :: Custom a
      , cs_docs             :: HolDocuments d a => d a       
      }    
    
instance (HolDocuments d a, Binary a) => Binary (CrawlerState d a) where
  put (CrawlerState tbp wp dh _ _ _ _ _ _ _ d) 
    = put tbp >> put wp >> put dh >> put d
      
  get = do
        tbp <- get
        wp  <- get
        dh  <- get
        d   <- get
        return $ CrawlerState tbp wp dh (ids d) [] Nothing this (constA []) (const False) (constA Nothing) d 
        where
          ids d =  [1..] \\ (IM.keys $ toMap d) 


-- | Extract References to other documents from a XmlTree based on configured XPath expressions
getReferencesByXPaths :: ArrowXml a => [String] -> a XmlTree [URI]
getReferencesByXPaths xpaths
  = listA (getRefs' $< computeDocBase) -- >>^ concat
    where
    getRefs' base = catA $ map (\x -> getXPathTrees x >>> getText >>^ toAbsRef) xpaths
      where
      toAbsRef ref = removeFragment $ fromMaybe ref $ expandURIString ref base
      removeFragment r
              | "#" `isPrefixOf` path = reverse . tail $ path
              | otherwise = r
              where
                path = dropWhile (/='#') . reverse $ r 



parseWords  :: (Char -> Bool) -> String -> [String]
parseWords isWordChar'
          = filter (not . null) . words . map boringChar
          where
          boringChar c             -- these chars separate words
            | isWordChar' c = c
            | otherwise    = ' '

isWordChar  :: Char -> Bool
isWordChar c = isAlphaNum c || c `elem` ".-_'@" 


instance XmlPickler IndexerConfig where
  xpickle = xpWrap  ( \(sp, tp, ip, cc, cf, ra) -> IndexerConfig sp tp ip cc cf ra
                    , \(IndexerConfig sp tp ip cc cf ra) -> (sp, tp, ip, cc, cf, ra)
                    ) xpConfig
    where
    xpConfig = xp6Tuple xpStartPages xpTmpPath xpIdxPath xpContextConfigs xpFCrawlFilter xpReadAttrs
      where
      xpStartPages     = xpElem "StartPages" $ xpList   $ xpElem "Page"       xpPrim 
      xpTmpPath        = xpOption $ xpElem "TmpPath"    xpPrim
      xpIdxPath        =            xpElem "OutputPath" xpPrim
      xpContextConfigs = xpElem "ContextConfigurations" $ xpList $ xpContextConfig
      xpContextConfig  = xpZero
      xpFCrawlFilter   = xpZero
      xpReadAttrs      = xpZero

         
-- | create an initial CrawlerState from an IndexerConfig
initialCrawlerState :: (HolDocuments d a, Binary a) => IndexerConfig -> d a -> Custom a -> CrawlerState d a
initialCrawlerState cic emptyDocuments getCustom
  = CrawlerState
    { cs_toBeProcessed  = S.fromList (ic_startPages cic)
    , cs_wereProcessed  = S.empty
    , cs_unusedDocIds   = [1..]
    , cs_readAttributes = ic_readAttributes cic
    , cs_fGetReferences = getReferencesByXPaths ["//a/@href/text()", "//frame/@src/text()", "//iframe/@src/text()"]
    , cs_fPreFilter     = (none `when` isText) -- this
    , cs_fCrawlFilter   = ic_fCrawlFilter cic
    , cs_docs           = emptyDocuments
    , cs_tempPath       = ic_tmpPath cic
    , cs_fGetCustom     = getCustom
    , cs_docHashes      = M.empty
    }
   
    
saveCrawlerState :: (HolDocuments d a, Binary a) => FilePath -> CrawlerState d a -> IO ()
saveCrawlerState fp cs = writeToBinFile fp cs

loadCrawlerState :: (HolDocuments d a , Binary a) => FilePath -> CrawlerState d a -> IO (CrawlerState d a)
loadCrawlerState fp ori = do
                          cs <- decodeFile fp
                          return $! cs { cs_readAttributes = cs_readAttributes ori
                                    , cs_fPreFilter     = cs_fPreFilter     ori
                                    , cs_fGetReferences = cs_fGetReferences ori
                                    , cs_tempPath       = cs_tempPath       ori
                                    , cs_fGetCustom     = cs_fGetCustom     ori
                                    }    
                                    
                                    -- -----------------------------------------------------------------------------
-- | Merge Indexer Configs. Basically the first IndexerConfig is taken and
--   the startPages of all other Configs are added. The crawl filters are OR-ed
--   so that more pages might be indexed. So you better know what you are doing
--   when you are using this.

mergeIndexerConfigs :: IndexerConfig -> IndexerConfig -> IndexerConfig
mergeIndexerConfigs cfg1 cfg2 = mergeIndexerConfigs' cfg1 [cfg2]

mergeIndexerConfigs' :: IndexerConfig -> [IndexerConfig] -> IndexerConfig
mergeIndexerConfigs' cfg1 [] = cfg1
mergeIndexerConfigs' cfg1 (cfg2:cfgs) = mergeIndexerConfigs' resCfg cfgs
  where 
  resCfg = IndexerConfig
      ((ic_startPages cfg1) ++ (ic_startPages cfg2))
      (ic_tmpPath cfg1)
      (ic_idxPath cfg1)
      (ic_contextConfigs cfg1)  -- cfg2, too?
      (\a -> (ic_fCrawlFilter cfg1) a || (ic_fCrawlFilter cfg2) a)
      (ic_readAttributes cfg1)


{- | Create Crawl filters based on regular expressions. The first Parameter defines the default 
     value if none of the supplied rules matches. The rule list is computed from the first element
     to the last. The first rule that matches the URI is applied. 
     
     example:
     
     > crawlFilter False [ ("\/a\/b\/z", True )
     >                   , ("\/a\/b"  , False)
     >                   , ("\/a"    , True )

     The default value for the filter is False like it will be in most cases unless you are trying
     to use Holumbus to build a google replacement. If you read the rules from bottom to top, all
     documents in "\/a" will be included (which should be a single domain or ip address or maybe a
     set of these). The second rule disables the directory "\/a\/b" but with the first rule, the 
     subdirectory z is included again and "\/a\/b\/a" to "\/a\/b\/y" are excluded. Even though this could
     also be done with the 'simpleCrawlFilter', this way saves you a lot of unnecessary code.
-} 
crawlFilter :: Bool -> [(String, Bool)] -> (URI -> Bool)
crawlFilter theDefault [] _ = theDefault
crawlFilter theDefault ((expr, b):expressions) theUri = 
  if isJust $ matchRegex (mkRegex expr) theUri then b else crawlFilter theDefault expressions theUri

-- | Create Crawl filters based on regular expressions. The first list defines 
--   regular expression of URIs that have to be crawled. Any new URI must match at least one of 
--   these regular expressions to be crawled. The second list consists of regular expressions for
--   pages that must not be crawled. This can be used to limit the set of documents defined by 
--   the including expressions. 
simpleCrawlFilter :: [String] -> [String] -> (URI -> Bool)
simpleCrawlFilter as ds theUri = isAllowed && (not isForbidden ) 
         where
         isAllowed   = foldl (&&) True  (map (matches theUri) as)
         isForbidden = foldl (||) False (map (matches theUri) ds)
         matches u a = isJust $ matchRegex (mkRegex a) u      
      
-- | some standard options for the readDocument function
standardReadDocumentAttributes :: [(String, String)]
standardReadDocumentAttributes = []
  ++ [ (a_parse_html,        v_1)]
  ++ [ (a_issue_warnings,    v_0)]
  ++ [ (a_remove_whitespace, v_1)]
  ++ [ (a_tagsoup,           v_1)]
  ++ [ (a_use_curl,          v_1)]
  ++ [ (a_options_curl,      "--user-agent HolumBot/0.1@http://holumbus.fh-wedel.de --location")]     
  ++ [ (a_encoding,          isoLatin1)]      


