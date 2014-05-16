{-# LANGUAGE OverloadedStrings #-}

module Hayoo.Hunt.ApiDocument
where

import           Data.Digest.Murmur64
import qualified Data.Map.Strict              as SM
import qualified Data.Text                    as T

import           Hayoo.FunctionInfo
import           Hayoo.Hunt.IndexSchema
import           Hayoo.PackageInfo

import           Holumbus.Crawler.IndexerCore

import           Hunt.ClientInterface
-- import           Hunt.Common.ApiDocument
-- import           Hunt.Common.BasicTypes
import           Hunt.Common.DocDesc          (DocDesc (..))
import qualified Hunt.Common.DocDesc          as DD

-- ------------------------------------------------------------

toApiDoc :: ToDescr c => (URI, RawDoc c, Score) -> ApiDocument
toApiDoc (uri, (rawContexts, rawTitle, rawCustom), wght)
    = withDescription
         ( (if null rawTitle
            then id
            else DocDesc . SM.insert d'name (T.pack rawTitle) . unDesc
           ) $ toDescr rawCustom
         )
      . withIndex (SM.fromList . concatMap toCC $ rawContexts)
      . withDocWeight wght
      $ mkApiDoc uri
    where
      toCC (_,  []) = []
      toCC (cx, ws) = [(cxToHuntCx cx, T.pack . unwords . map fst $ ws)]

boringApiDoc :: ApiDocument -> Bool
boringApiDoc a
    = SM.null (adIndex a) && DD.null (adDescr a) && (maybe 1.0 id $ adWght a) == 1.0

lookupIndexMap :: Context -> ApiDocument -> T.Text
lookupIndexMap cx d
    = maybe "" id . SM.lookup cx . adIndex $ d

-- ------------------------------------------------------------

-- auxiliary types for ToDescr instances

newtype FctDescr  = FD FunctionInfo
newtype PkgDescr  = PD PackageInfo
newtype RankDescr = RD () -- old: Score

class ToDescr a where
    toDescr :: a -> Description

instance ToDescr a => ToDescr (Maybe a) where
    toDescr Nothing  = DD.empty
    toDescr (Just x) = toDescr x

instance ToDescr FctDescr where
    toDescr (FD x) = fiToDescr x

instance ToDescr RankDescr where
    toDescr (RD _) = mkDescr [] -- old: [(d'rank, rankToText r)]

instance ToDescr PkgDescr where
    toDescr (PD x) = piToDescr x

instance Hashable64 FctDescr where
    hash64Add (FD (FunctionInfo _mon sig pac sou fct typ))
        = hash64Add [sig, pac, sou, fct, show typ]

fiToHash :: String -> FunctionInfo -> Int
fiToHash name fi = fromInteger . fromIntegral . asWord64 . hash64Add name . hash64 . FD $ fi

fiToPkg :: FunctionInfo -> T.Text
fiToPkg (FunctionInfo _mon _sig pac _sou _fct _typ)
    = T.pack pac

-- ----------------------------------------

mkDescr :: [(T.Text, T.Text)] -> Description
mkDescr = DD.fromList . filter (not . T.null . snd)

fiToDescr :: FunctionInfo -> Description
fiToDescr (FunctionInfo mon sig pac sou fct typ)
    = mkDescr
      [ (d'module,      T.pack                   mon)
      , (d'signature,   T.pack . cleanupSig    $ sig)
      , (d'package,     T.pack                   pac)
      , (d'source,      T.pack                   sou)
      , (d'description, T.pack . cleanupDescr  $ fct)
      , (d'type,        T.pack . drop 4 . show $ typ)
      ]

piToDescr :: PackageInfo -> Description
piToDescr (PackageInfo nam ver dep aut mai cat hom syn des upl ran)
    = mkDescr
      [ (d'name,         T.pack nam)
      , (d'version,      T.pack ver)
      , (d'dependencies, T.pack dep)
      , (d'author,       T.pack aut)
      , (d'maintainer,   T.pack mai)
      , (d'category,     T.pack cat)
      , (d'homepage,     T.pack hom)
      , (d'synopsis,     T.pack syn)
      , (d'description,  T.pack des)
      , (d'upload,       T.pack upl)
      , (d'type,         "package")
      , (d'rank,         rankToText ran)
      ]

rankToText :: Score -> T.Text
rankToText r
    | r == defPackageRank = T.empty
    | otherwise           = T.pack . show $ r

-- HACK: the old Hayoo index contains keywords in the signature for type of object
-- these are removed, the type is encoded in the type field

cleanupSig :: String -> String
cleanupSig ('!' : s) = s
cleanupSig "class"   = ""
cleanupSig "data"    = ""
cleanupSig "module"  = ""
cleanupSig "newtype" = ""
cleanupSig "type"    = ""
cleanupSig x         = x

-- some descriptions consist of the single char "&#160;" (aka. nbsp),
-- these are removed

cleanupDescr :: String -> String
cleanupDescr "&#160;" = ""
cleanupDescr d        = d

-- ------------------------------------------------------------
