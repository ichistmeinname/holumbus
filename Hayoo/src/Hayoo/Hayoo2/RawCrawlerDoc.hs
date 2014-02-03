{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

-- ------------------------------------------------------------

module Hayoo.Hayoo2.RawCrawlerDoc
where

-- ------------------------------------------------------------

-- import           Control.DeepSeq

import           Data.Aeson
import           Data.Aeson.Encode.Pretty
import           Data.Aeson.Types             (Pair)
import qualified Data.ByteString.Lazy         as LB
import qualified Data.HashMap.Strict          as M
import           Data.Monoid
import qualified Data.Text                    as T

import           Holumbus.Crawler
import           Holumbus.Crawler.IndexerCore

-- ------------------------------------------------------------
--
-- conversion to JSON of a raw doc is a bit tricky
-- the title attribute must be merged into the custom object
-- to get all attributes together, so we need this hack with addPair

newtype RawCrawlerDoc c         = RCD (URI, RawDoc c)

instance (ToJSON c) => ToJSON (RawCrawlerDoc c) where
    toJSON (RCD (rawUri, (rawContexts, rawTitle, rawCustom)))
        = object [ "cmd"      .= ("update" :: T.Text)
                 , "document" .= doc
                 ]
        where
          doc = object
                [ "uri"        .= rawUri
                , ("description", addPair ("title", toJSON rawTitle) $
                                  toJSON rawCustom
                  )
                , "index"      .= object (map toJSONRawContext rawContexts)
                ]

toJSONRawContext :: RawContext -> Pair
toJSONRawContext (cx, ws) = T.pack cx .= toJSONRawWords ws

toJSONRawWords :: RawWords -> Value
toJSONRawWords = toJSON . T.pack . unwords . map fst

addPair :: Pair -> Value -> Value
addPair (k, v) (Object m) = Object $ M.insert k v m
addPair p      _          = object [p]

flushRawCrawlerDoc :: (ToJSON c) => Bool -> (LB.ByteString -> IO ()) -> c -> IO ()
flushRawCrawlerDoc pretty io d
    = io $ (if pretty then encodePretty' encConfig else encode) d
      where
        encConfig :: Config
        encConfig
            = Config { confIndent = 2
                     , confCompare
                         = keyOrder ["uri", "description", "index"]
                           `mappend`
                           compare
                     }

-- ------------------------------------------------------------