-- ----------------------------------------------------------------------------

{- |
  Module     : WebSearch
  Copyright  : Copyright (C) 2007 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.3

  An example of how Holumbus can be used together with the Janus application
  server to create a web service.
 
-}

-- ----------------------------------------------------------------------------

{-# OPTIONS -fglasgow-exts -farrows #-}

module Network.Server.Janus.Shader.WebSearch where

import Text.XML.HXT.Arrow

--import Holumbus.Index.Common
import Holumbus.Index.Combined
import Holumbus.Index.Inverted

import Holumbus.Query.Syntax
import Holumbus.Query.Parser
import Holumbus.Query.Processor
import Holumbus.Query.Result
import Holumbus.Query.Ranking
import Holumbus.Query.Fuzzy

import Network.Server.Janus.Core
import Network.Server.Janus.XmlHelper
import Network.Server.Janus.JanusPaths

import Control.Concurrent  -- For the global MVar

import Network.CGI         -- For decoding URI-encoded strings

-- Status information of query processing.
type StatusResult = (Status, Result)
type Status = (String, Int, Float, Int, Float)

websearchShader :: ShaderCreator
websearchShader = mkDynamicCreator $ proc (_, _) -> do
  tmp <- arrIO $ loadFromFile -< "indexes/vl.xml" -- Should be configurable (from Context)
  mix <- arrIO $ newMVar -< Inv tmp
  returnA -< websearchService mix

websearchService :: MVar AnyIndex -> Shader
websearchService mix = proc inTxn -> do
  idx      <- arrIO $ readMVar                                             -< mix
  request  <- getValDef (_transaction_http_request_cgi_ "@query") ""       -< inTxn
  response <- writeString <<< (genError ||| genResult) <<< (arrParseQuery) -< (urlDecode request, idx)
  setVal _transaction_http_response_body response                          -<< inTxn    
    where
    writeString = pickleStatusResult >>> (writeDocumentToString [(a_indent, v_1), (a_output_encoding, isoLatin1)])
    pickleStatusResult = xpickleVal xpStatusResult

arrParseQuery :: ArrowXml a => a (String, AnyIndex) (Either (String, AnyIndex) (Query, AnyIndex))
arrParseQuery = arr $ (\(r, i) -> either (\m -> Left (m, i)) (\q -> Right (q, i)) (parseQuery r))

genResult :: ArrowXml a => a (Query, AnyIndex) (Status, Result)
genResult = (arr $ (\(q, i) -> (makeQuery i q, i)))
            >>>
            (first $ arr $ rank)
            >>>
            (arr $ (\(r, i) -> annotateResult i r))
            >>>
            (arr $ (\r -> (setResult r defaultStatus , r)))

makeQuery :: AnyIndex -> Query -> Result
makeQuery i q = if checkWith ((> 1) . length) q then
                processQuery cfg i (optimize q)
                else emptyResult
                  where
                  cfg = ProcessConfig [] (FuzzyConfig True True 1.0 germanReplacements)

genError :: ArrowXml a => a (String, AnyIndex) (Status, Result)
genError = arr $ (\(msg, _) -> (setMessage msg defaultStatus, emptyResult))

xpStatusResult :: PU StatusResult
xpStatusResult = xpElem "holumbus" (xpPair xpStatus xpResult)

xpStatus :: PU Status
xpStatus = xpElem "status" (xp5Tuple (xpElem "message" xpPrim)
           (xpElem "doccount" xpPrim) (xpElem "docscore" xpPrim)
           (xpElem "wordcount" xpPrim) (xpElem "wordscore" xpPrim))

defaultStatus :: Status
defaultStatus = ("", 0, 0.0, 0, 0.0)

setResult :: Result -> Status -> Status
setResult r (m, _, _, _, _) = (m, sizeDocs r, maxScoreDocs r, sizeWords r, maxScoreWords r)

setMessage :: String -> Status -> Status
setMessage m (_, dh, ds, wh, ws) = (m, dh, ds, wh, ws)