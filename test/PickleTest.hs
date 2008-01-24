-- ----------------------------------------------------------------------------

{- |
  Module     : Pickle
  Copyright  : Copyright (C) 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.1

  The some unit tests for the Holumbus bijective map.

-}

-- ----------------------------------------------------------------------------

module PickleTest (allTests) where

import Holumbus.Index.Inverted
import Holumbus.Query.Result

import Data.Maybe

import Text.XML.HXT.Arrow

import Test.HUnit

import SampleData

testIndex1, testIndex2 :: InvIndex
testIndex1 = empty
testIndex2 = sampleIndex1

testResult1, testResult2 :: Result
testResult1 = emptyResult
testResult2 = sampleResult1

-- Stolen from the HXT pickle tests. Thanks :)
pickleUnpickleTests :: (XmlPickler p, Eq p, Show p) => [p] -> PU p -> String -> Test
pickleUnpickleTests input pickler desc = TestLabel ("Pickle/unpickle tests with " ++ desc) $
                                         TestList $ map makeTests input
  where
  makeTests i = TestList $
    [ TestCase $ assertEqual "pickleDoc/unpickleDoc without XML serialisation: " [i] res1

    , TestCase $ assertEqual "pickleDoc/unpickleDoc with xshow/xread: " [i] res2

    , TestCase $
      do
      res <- res4
      assertEqual "pickle/unpickle with readFromString: " [i] res

    , TestCase $ res5 >>= assertEqual "pickle/unpickle with writeDocument/readDocument: " [i]

    , TestCase $ res6 >>= assertEqual "pickle/unpickle with xpickleDocument/xunpickleDocument: " [i]
{-
FIXME TH 15.01.2008: See below
    , TestCase $
      res7 >>= 
      assertEqual "pickle/unpickle with DTD validation xpickleDocument/xunpickleDocument: " [i]
-}
    ]
    where
    res1 = maybeToList . unpickleDoc pickler . pickleDoc pickler $ i
  
    res2 = runLA (xshow (arr (pickleDoc pickler) 
             >>> getChildren)
             >>> root [] [xread]
             >>> arrL (maybeToList . unpickleDoc pickler)) i
  
    res4 = runX (constA i
            >>> arr (pickleDoc pickler)                   -- InvIndex => XmlTree
            >>> writeDocumentToString []                  -- XmlTree => String
            >>> readFromString [(a_validate, v_0)]        -- String => XmlTree
            >>> arrL (maybeToList . unpickleDoc pickler)) -- XmlTree => InvIndex
  
    res5 = runX (constA i                                    -- Take the InvIndex value
            >>> arr (pickleDoc pickler)                      -- InvIndex => XmlTree
            >>> writeDocument [(a_indent, v_1)] "data/pickle.xml" -- XmlTree => formated external XML document
            >>> readDocument  [(a_remove_whitespace, v_1), (a_validate, v_0)] "data/pickle.xml" -- Formated external XML document => XmlTree 
            >>> arrL (maybeToList . unpickleDoc pickler))    -- XmlTree => InvIndex
  
    res6 = runX (constA i -- Same as above the convinient way
            >>> xpickleDocument pickler [(a_indent, v_1)] "data/pickle.xml"
            >>> xunpickleDocument pickler [(a_remove_whitespace, v_1), (a_validate, v_0)] "data/pickle.xml")

{-
FIXME TH 15.01.2008: Adding a DTD automatically does not work yet, because we use
                     the doc element twice with different meanings: Once as part of the
                     document table and as part of an index, too  
    res7 :: IO [InvIndex]                                    -- Same as above with validation
    res7 = runX (constA i
            >>> xpickleDocument xpInvIndex [(a_indent, v_1), (a_addDTD, v_1)] "data/pickle.xml"
            >>> xunpickleDocument xpInvIndex [(a_remove_whitespace, v_1), (a_validate, v_1)] "data/pickle.xml")
--}

allTests :: Test  
allTests = TestList [ pickleUnpickleTests [testIndex1, testIndex2] xpInvIndex "InvIndex"
                    , pickleUnpickleTests [testResult1, testResult2] xpResult "Result"
                    ]
