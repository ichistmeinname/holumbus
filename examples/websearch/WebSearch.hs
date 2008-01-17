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

{-# OPTIONS -fglasgow-exts -farrows -fno-warn-type-defaults #-}

module Network.Server.Janus.Shader.WebSearch where

import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.IntMap as IM

import Text.XML.HXT.Arrow
import Text.XML.HXT.DOM.Unicode

import Holumbus.Index.Combined
import Holumbus.Index.Inverted
import Holumbus.Index.Documents
import Holumbus.Index.Common

import Holumbus.Query.Syntax
import Holumbus.Query.Parser
import Holumbus.Query.Processor
import Holumbus.Query.Result
import Holumbus.Query.Ranking
import Holumbus.Query.Fuzzy

import Network.Server.Janus.Core (Shader, ShaderCreator)
import qualified Network.Server.Janus.Core as J
import Network.Server.Janus.XmlHelper
import Network.Server.Janus.JanusPaths

import System.Time

import Control.Concurrent  -- For the global MVar

import Network.CGI         -- For decoding URI-encoded strings

-- Status information of query processing.
type StatusResult = (String, Result)

websearchShader :: ShaderCreator
websearchShader = J.mkDynamicCreator $ proc (_, _) -> do
  tmp <- arrIO $ loadFromFile -< "indexes/sd.xml" -- Should be configurable (from Context)
  mix <- arrIO $ newMVar -< Inv tmp
  returnA -< websearchService mix

websearchService :: MVar AnyIndex -> Shader
websearchService mix = proc inTxn -> do
  idx      <- arrIO $ readMVar                                             -< mix
  request  <- getValDef (_transaction_http_request_cgi_ "@query") ""       -< inTxn
  arrLogRequest                                                            -< inTxn
  response <- writeString <<< (genError ||| genResult) <<< (arrParseQuery) -< (request, idx)
  setVal _transaction_http_response_body response                          -<< inTxn    
    where
    writeString = pickleStatusResult >>> (writeDocumentToString [(a_no_xml_pi, v_1), (a_output_encoding, utf8)])
    pickleStatusResult = xpickleVal xpStatusResult

arrParseQuery :: ArrowXml a => a (String, AnyIndex) (Either (String, AnyIndex) (Query, AnyIndex))
arrParseQuery = (first arrDecode)
                >>>
                (arr $ (\(r, i) -> either (\m -> Left (m, i)) (\q -> Right (q, i)) (parseQuery r)))

arrDecode :: Arrow a => a String String
arrDecode = arr $ fst . utf8ToUnicode . urlDecode

arrLogRequest :: JanusArrow J.Context XmlTree ()
arrLogRequest = proc inTxn -> do
  remHost <- getValDef (_transaction_tcp_remoteHost) ""                -< inTxn
  rawRequest <- getValDef (_transaction_http_request_cgi_ "@query") "" -< inTxn
  decodedRequest <- arrDecode                                          -< rawRequest
  unixTime <- arrIO $ (\_ -> getClockTime)                             -< ()
  currTime <- arr $ calendarTimeToString . toUTCTime                   -< unixTime
  arrIO $ putStrLn -< (currTime ++ " - " ++ remHost ++ " - " ++ rawRequest ++ " - " ++ decodedRequest)

genResult :: ArrowXml a => a (Query, AnyIndex) (String, Result)
genResult = ifP (\(q, _) -> checkWith ((> 1) . length) q)
              ((arr $ (\(q, i) -> (makeQuery i q, i)))
              >>>
              (first $ arr $ rank)
              >>>
              (arr $ (\(r, i) -> annotateResult i r))
              >>>
              (arr $ (\r -> (msgSuccess r , r))))
              
              (arr $ (\(_, _) -> ("Please enter some more characters.", emptyResult)))

msgSuccess :: Result -> String
msgSuccess r = if sd == 0 then "Nothing found yet." 
               else "Found " ++ (show sd) ++ " " ++ ds ++ " and " ++ (show sw) ++ " " ++ cs ++ "."
                 where
                 sd = sizeDocHits r
                 sw = sizeWordHits r
                 ds = if sd == 1 then "document" else "documents"
                 cs = if sw == 1 then "completion" else "completions"

-- | This is where the magic happens!
makeQuery :: AnyIndex -> Query -> Result
makeQuery i q = processQuery cfg i (optimize q)
                  where
                  cfg = ProcessConfig [] (FuzzyConfig True True 1.0 germanReplacements)

genError :: ArrowXml a => a (String, AnyIndex) (String, Result)
genError = arr $ (\(msg, _) -> (msg, emptyResult))

xpStatusResult :: PU StatusResult
xpStatusResult = xpElem "div" $ xpAddFixedAttr "id" "result" $ xpPair xpStatus xpResultHtml

xpStatus :: PU String
xpStatus = xpElem "div" $ xpAddFixedAttr "id" "status" xpText

-- The HTML Result pickler

xpResultHtml :: PU Result
xpResultHtml = xpWrap (\((_, wh), dh) -> Result dh wh, \r -> ((maxScoreWordHits r, wordHits r), docHits r)) 
               (xpPair xpWordHitsHtml xpDocHitsHtml)

-- | Wrapping something in a <div> element with id attribute.
xpDivId :: String -> PU a -> PU a
xpDivId i p = xpElem "div" (xpAddFixedAttr "id" i p)

-- | Set the class of the surrounding element.
xpClass :: String -> PU a -> PU a
xpClass c p = xpAddFixedAttr "class" c p

xpAppend :: String -> PU a -> PU a
xpAppend t p = xpWrap (\(v, _) -> v, \v -> (v, t)) (xpPair p xpText)

xpPrepend :: String -> PU a -> PU a
xpPrepend t p = xpWrap (\(_, v) -> v, \v -> (t, v)) (xpPair xpText p)

-- | The HTML pickler for the document hits. Will be sorted by score.
xpDocHitsHtml :: PU DocHits
xpDocHitsHtml = xpDivId "documents" (xpWrap (IM.fromList, toListSorted) (xpList xpDocHitHtml))
  where
  toListSorted = reverse . L.sortBy (compare `on` (docScore . fst . snd)) . IM.toList -- Sort by score
  xpDocHitHtml = xpElem "p" $ xpClass "document" $ xpDocInfoHtml

xpDocInfoHtml :: PU (DocId, (DocInfo, DocContextHits))
xpDocInfoHtml = xpWrap (docFromHtml, docToHtml) (xpTriple xpTitleHtml xpContextsHtml xpURIHtml)

docToHtml :: (DocId, (DocInfo, DocContextHits)) -> ((URI, Title), DocContextHits, URI)
docToHtml (_, (DocInfo (title, uri) _, dch)) = ((uri, title), dch, uri)

docFromHtml :: (Document, DocContextHits, URI) -> (DocId, (DocInfo, DocContextHits))
docFromHtml ((uri, title), dch, _) = (0, (DocInfo (title, uri) 0.0, dch))

xpTitleHtml :: PU (URI, Title)
xpTitleHtml = xpElem "div" $ xpClass "title" $ xpElem "a" $ xpClass "link" $ (xpPair (xpAttr "href" xpText) xpText)

xpContextsHtml :: PU DocContextHits
xpContextsHtml = xpElem "div" $ xpClass "contexts" $ xpWrap (M.fromList, M.toList) (xpList xpContextHtml)

xpContextHtml :: PU (Context, DocWordHits)
xpContextHtml = xpPair (xpElem "span" $ xpClass "context" $ xpAppend ": " $ xpText) xpWordsHtml

xpWordsHtml :: PU DocWordHits
xpWordsHtml = xpWrap (M.fromList, M.toList) (xpList (xpPair (xpAppend " " $ xpText) xpZero))

xpURIHtml :: PU String
xpURIHtml = xpElem "div" $ xpClass "uri" $ xpText

xpWordHitsHtml :: PU (Score, WordHits)
xpWordHitsHtml = xpDivId "words" $ xpElem "p" $ xpClass "cloud" $ xpWrap (fromListSorted, toListSorted) (xpList xpWordHitHtml)
  where
  fromListSorted _ = (0.0, M.empty)
  toListSorted (s, wh) = map (\a -> (s, a)) $ L.sortBy (compare `on` fst) $ M.toList wh -- Sort by word
  xpWordHitHtml = xpWrap (wordFromHtml, wordToHtml) (xpWordHtml)

wordToHtml :: (Score, (Word, (WordInfo, WordContextHits))) -> ((String, Word), ((Score, Score), Word))
wordToHtml (m, (w, (WordInfo ts s, _))) = ((head ts, w), ((s, m), w))

wordFromHtml :: ((String, Word), ((Score, Score), Word)) -> (Score, (Word, (WordInfo, WordContextHits)))
wordFromHtml ((t, _), ((s, m), w)) = (m, (w, (WordInfo [t] s, M.empty)))

xpWordHtml :: PU ((String, Word), ((Score, Score), Word))
xpWordHtml = xpAppend " " $ xpElem "a" $ xpClass "cloud" $ xpPair xpLink xpScore

xpLink :: PU (String, Word)
xpLink = xpAttr "href" $ xpPair (xpPrepend "javascript:replaceInQuery('" $ xpAppend "','" xpText) (xpAppend "')" $ xpText)

xpScore :: PU ((Score, Score), Word)
xpScore = xpElem "span" $ xpPair (xpAttr "class" $ xpWrap (scoreFromHtml, scoreToHtml) xpText) xpText

weightScore :: Score -> Score -> Score -> Score -> Score
weightScore mi ma to v = ma - ((to - v) / to) * (ma - mi)

scoreToHtml :: (Score, Score) -> String
scoreToHtml (v, top) = "cloud" ++ (show $ round (weightScore 1 9 top v))

scoreFromHtml :: String -> (Score, Score)
scoreFromHtml _ = (0.0, 0.0)

-- This is a fix for GHC 6.6.1 (from 6.8.1 on, this is avaliable in module Data.Function)
on :: (b -> b -> c) -> (a -> b) -> a -> a -> c
op `on` f = \x y -> f x `op` f y
