{-# OPTIONS #-}

-- ------------------------------------------------------------

module Hayoo.IndexTypes
    ( module Hayoo.IndexTypes
    , Document
    )
where

import           Control.DeepSeq

import           Data.Binary
import qualified Data.ByteString.Char8		as C
import qualified Data.IntSet			as IS
import qualified Data.IntMap			as IM
import           Data.List			( foldl' )
import           Data.Maybe

import		 Hayoo.FunctionInfo
import		 Hayoo.PackageInfo

import		 Holumbus.Crawler
import		 Holumbus.Crawler.IndexerCore

import           Holumbus.Index.Common		( Document
                                                , Occurrences
                                                , custom, editDocIds, removeById, toMap, updateDocIds'
                                                )
import           Holumbus.Index.Documents       ( Documents(..)
                                                , emptyDocuments
                                                )

-- ------------------------------------------------------------

{- .1: direct use of prefix tree with simple-9 encoded occurences

   concerning efficiency this implementation is about the same as the 2. one,
   space and time are minimally better, the reason could be less code working with classes

import		 Holumbus.Index.Inverted.PrefixMem

-}
-- ------------------------------------------------------------

{- .2: indirect use of prefix tree with simple-9 encoded occurences via InvertedCompressed

   minimal overhead compared to .1
   but less efficient in time (1598s / 1038s) and space
   total mem use (2612MB / 2498MB) than .3

import qualified Holumbus.Index.Inverted.CompressedPrefixMem	as PM

type Inverted			= PM.InvertedCompressed

emptyInverted			:: Inverted
emptyInverted			= PM.emptyInvertedCompressed
-}

-- ------------------------------------------------------------

{- .3: indirect prefix tree without compression of position sets

   best of these 3 implementations

   implementations with serializations become much more inefficient
   in runtime and are not worth to be considered
-}
 
import qualified Holumbus.Index.Inverted.CompressedPrefixMem	as PM

type Inverted			= PM.Inverted0

emptyInverted			:: Inverted
emptyInverted			= PM.emptyInverted0

removeDocIdsInverted 		:: Occurrences -> Inverted -> Inverted
removeDocIdsInverted		= PM.removeDocIdsInverted

-- ------------------------------------------------------------

type HayooState  di        	= IndexerState       Inverted Documents di
type HayooConfig di        	= IndexCrawlerConfig Inverted Documents di

type HayoorCrawlerState	di 	= CrawlerState (HayooState di)

emptyHayooState			:: HayooState di
emptyHayooState			= emptyIndexerState emptyInverted emptyDocuments

-- ------------------------------------------------------------

getPkgNameFct			:: Document FunctionInfo -> String
getPkgNameFct			= C.unpack . package . fromJust . custom

getPkgNamePkg			:: Document PackageInfo -> String
getPkgNamePkg			= C.unpack . p_name . fromJust . custom

-- ------------------------------------------------------------

removePackages'			:: (Binary di, NFData di) =>
                                   (Document di -> String) -> String -> [String] -> Bool -> IO (HayooState di)
removePackages' pkgName ixName pkgList defragment
				= do
                                  ix <- decodeFile ixName
                                  let ix1  = removePack' pkgName pkgList ix
                                  let ix2  = if defragment
	                                     then defragmentIndex ix1
                                             else ix1
                                  rnf ix2 `seq` return ix2

-- ------------------------------------------------------------

removePack'			:: (Binary di) =>
                                   (Document di -> String) -> [String] ->
                                   HayooState di -> HayooState di
removePack' pkgName ps IndexerState
              { ixs_index     = ix
              , ixs_documents = ds
              }			= IndexerState
                                  { ixs_index	  = ix'
                                  , ixs_documents = ds'
                                  }
    where
							-- collect all DocIds used in the given packages
    docIds			= IM.foldWithKey checkDoc IM.empty . toMap $ ds
    checkDoc did doc xs
        | docPartOfPack		= IM.insert did IS.empty xs
        | otherwise		=                        xs
        where
        docPartOfPack		= (`elem` ps) . pkgName $ doc

							-- remove all DocIds from index
    ix'				= removeDocIdsInverted docIds ix

							-- restrict document table
    ds'				= foldl' removeById ds $ IM.keys docIds

-- ------------------------------------------------------------

defragmentIndex			:: (Binary di) =>
                                   HayooState di -> HayooState di
defragmentIndex IndexerState
              { ixs_index     = ix
              , ixs_documents = ds
              }			= IndexerState
                                  { ixs_index	  = ix'
                                  , ixs_documents = ds'
                                  }
    where
    ix'				= updateDocIds' editId ix
    ds'				= editDocIds editId ds
    idMap			= IM.fromList . flip zip [1..] . IM.keys . toMap $ ds
    editId i			= fromJust . IM.lookup i $ idMap

-- ------------------------------------------------------------

type HayooIndexerState         		= HayooState   FunctionInfo
type HayooIndexerConfig        		= HayooConfig  FunctionInfo

type HayooIndexerCrawlerState		= CrawlerState HayooIndexerState

-- ------------------------------------------------------------

type HayooPkgIndexerState         	= HayooState   PackageInfo
type HayooPkgIndexerConfig        	= HayooConfig  PackageInfo

type HayooPkgIndexerCrawlerState	= CrawlerState HayooPkgIndexerState

-- ------------------------------------------------------------
