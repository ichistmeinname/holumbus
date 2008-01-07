-- ----------------------------------------------------------------------------

{- |
  Module     : Holumbus.Query.Fuzzy
  Copyright  : Copyright (C) 2007 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.1

  The unique Holumbus mechanism for generating fuzzy sets.

-}

-- ----------------------------------------------------------------------------

module Holumbus.Query.Fuzzy 
  (
  -- * Fuzzy types
  FuzzySet
  , Replacements
  , Replacement
  , Score
  
  -- * Predefined replacements
  , englishReplacements
  , germanReplacements
  
  -- * Generation
  , fuzz
  , fuzzWith
  , fuzzMore
  , fuzzMoreWith
  , fuzzUntil
  , fuzzUntilWith
  
  -- * Conversion
  , toList
  )
where

import Data.List

import Data.Map (Map)
import qualified Data.Map as M

type FuzzySet = Map String Score
type Replacements = [ Replacement ]
type Replacement = ((String, String), Score)
type Score = Float

-- | The default replacements to use in the functions without explicitly specified replacements.
defaultReplacements :: Replacements
defaultReplacements = germanReplacements

-- | Some default replacements for the english language.
englishReplacements :: Replacements
englishReplacements =
  [ (("l", "ll"), 0.2)
  , (("t", "tt"), 0.2)
  , (("r", "rr"), 0.2)
  ]

-- | Some default replacements for the german language.
germanReplacements :: Replacements
germanReplacements = 
  [ (("l", "ll"), 0.2)
  , (("t", "tt"), 0.2)
  , (("n", "nn"), 0.2)
  , (("r", "rr"), 0.2)
  , (("i", "ie"), 0.2)
  , (("ei", "ie"), 0.2)
  , (("k", "ck"), 0.2)

  , (("d", "t"), 0.4)
  , (("b", "p"), 0.4)
  , (("g", "k"), 0.4)
  , (("g", "ch"), 0.4)
  , (("c", "k"), 0.4)
  , (("s", "z"), 0.4)
  , (("u", "ou"), 0.4)

  , (("ü", "ue"), 0.1)
  , (("ä", "ae"), 0.1)
  , (("ö", "oe"), 0.1)
  , (("ß", "ss"), 0.1)
  ]

-- | Fuzz a string usind the default replacements.
fuzz :: String -> FuzzySet
fuzz = fuzzWith defaultReplacements

-- | Fuzz a string using an explicitly specified list of replacements.
fuzzWith :: Replacements -> String -> FuzzySet
fuzzWith = fuzzInternal 0.0

-- | Fuzz a set of fuzzy strings even more using the default replacements (the new set of 
-- fuzzy strings is not merged with the original set).
fuzzMore :: FuzzySet -> FuzzySet
fuzzMore = fuzzMoreWith defaultReplacements

-- | Fuzz a set of fuzzy strings even more using an explicitly specified list of replacements.
-- (the new set of fuzzy strings is not merged with the original set).
fuzzMoreWith :: Replacements -> FuzzySet -> FuzzySet
fuzzMoreWith rs fs = M.foldWithKey (\s sc res -> M.unionWith min res (fuzzInternal sc rs s)) M.empty fs

-- | Continue fuzzing a string with the default replacements until a given score threshold is reached.
fuzzUntil :: Score -> String -> FuzzySet
fuzzUntil = fuzzUntilWith defaultReplacements

-- | Continue fuzzing a string with the an explicitly specified list of replacements until 
-- a given score threshold is reached.
fuzzUntilWith :: Replacements -> Score -> String -> FuzzySet
fuzzUntilWith rs th s = fuzzUntilWith' (fuzzLimit th 0.0 rs s)
  where
  fuzzUntilWith' :: FuzzySet -> FuzzySet
  fuzzUntilWith' fs = if M.null more then fs else M.unionWith min fs (fuzzUntilWith' more)
    where
    -- The current score is doubled on every recursive call, because fuzziness increases exponentially.
    more = M.foldWithKey (\sm sc res -> M.unionWith min res (fuzzLimit th (sc + sc) rs sm)) M.empty fs

-- | Fuzz a string and limit the allowed score to a given threshold.
fuzzLimit :: Score -> Score -> Replacements -> String -> FuzzySet
fuzzLimit th sc rs s = if sc <= th then M.filter (\ns -> ns <= th) (fuzzInternal sc rs s) else M.empty

-- | Fuzz a string with an list of explicitly specified replacements and combine the scores
-- with an initial score.
fuzzInternal :: Score -> Replacements -> String -> FuzzySet
fuzzInternal sc rs s = foldr (\r res -> M.unionWith min res (applyReplacement sc rs s r)) M.empty rs

-- | Return the replacement strings in forward direction.
fwrd :: Replacement -> (String, String)
fwrd ((f, s), _) = (f, s)

-- | Return the replacement strings in backward direction.
bwrd :: Replacement -> (String, String)
bwrd ((f, s), _) = (s, f)

-- | Applies a single replacement definition (in both directions) to a string. An initial score is
-- combined with the new score for the replacement (calculated from the position in the string and 
-- the scores in the list of all replacements).
applyReplacement :: Score -> Replacements -> String -> Replacement -> FuzzySet
applyReplacement sc rs s r = apply (init $ inits s) (init $ tails s)
  where
  apply :: [ String ] -> [ String ] -> FuzzySet
  apply [] _ = M.empty
  apply _ [] = M.empty
  apply (pr:prs) (su:sus) = M.unionsWith min [apply' (fwrd r), apply' (bwrd r), apply prs sus]
    where
    apply' :: (String, String) -> FuzzySet
    apply' (tok, sub) = maybe M.empty fuzzySingleton (replacePosition pr su tok sub)
      where
      fuzzySingleton :: String -> FuzzySet
      fuzzySingleton rep = M.singleton rep (sc + calcScore (length pr) (length s) r rs)

-- | Replaces a prefix in the suffix of an already splitted string.
replacePosition :: String -> String -> String -> String -> Maybe String
replacePosition prefix suffix tok sub = if replaced == suffix then Nothing else Just (prefix ++ replaced)
  where
  replaced = replaceFirst tok sub suffix

-- | Calculate the final score of a replacement depending on the position in the string and the
-- length of the string. The score is normalized to the interval [0.0, 1.0]
calcScore :: Int -> Int -> Replacement -> Replacements -> Score
calcScore pos len r rs = relPos * relScore
  where
  relPos = (l - p) / l -- Normalized position (depending on the length of the string)
  relScore = (snd r) / (snd $ maximumBy (compare `on` snd) rs) -- Normalized score (depending on maximum score)
  p = fromIntegral pos
  l = fromIntegral len

-- | Searches a prefix and replaces it with a substitute in a list.
replaceFirst :: Eq a => [a] -> [a] -> [a] -> [a]
replaceFirst []       ys zs       = ys ++ zs
replaceFirst _        _ []       = []
replaceFirst t@(x:xs) ys s@(z:zs) = if x == z && t `isPrefixOf` s then 
                                      if null ys then replaceFirst xs [] zs 
                                      else (head ys) : replaceFirst xs (tail ys) zs
                                    else s

-- | Transform a fuzzy set into a list (ordered by score).
toList :: FuzzySet -> [ (String, Score) ]
toList = sortBy (compare `on` snd) . M.toList

-- This is a fix for GHC 6.6.1 (from 6.8.1 on, this is avaliable in module Data.Function)
on :: (b -> b -> c) -> (a -> b) -> a -> a -> c
(*) `on` f = \x y -> f x * f y