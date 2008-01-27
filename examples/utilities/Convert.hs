-- ----------------------------------------------------------------------------

{- |
  Module     : Convert
  Copyright  : Copyright (C) 2008 Timo B. Huebel
  License    : MIT

  Maintainer : Timo B. Huebel (t.h@gmx.info)
  Stability  : experimental
  Portability: portable
  Version    : 0.2

  Convert indexes between XML and binary format.

-}

-- ----------------------------------------------------------------------------

module Main where

import System.Exit
import System.IO
import System.Environment
import System.Console.GetOpt

import Control.Parallel.Strategies

import qualified Data.List as L

import Holumbus.Index.Inverted (InvIndex)
import Holumbus.Index.Documents (Documents)
import Holumbus.Index.Common

data Flag = Index String 
          | Documents String 
          | Format String
          | Output String
          | Version 
          | Help deriving (Show, Eq)

data Format = Binary
            | Xml

version :: String
version = "0.2"

main :: IO ()
main = do
       argv <- getArgs
       flags <- commandLineOpts argv
       if Version `elem` flags then (putStrLn version) >> (exitWith ExitSuccess) else return ()
       if Help `elem` flags then usage [] >> (exitWith ExitSuccess) else return ()

       input <- return (filter isInput flags)
       if null input then usage ["No input file given!\n"] else return ()
       if length input > 1 then usage ["Only one input file allowed!\n"] else return ()

       output <- return (filter isOutput flags)
       if null output then usage ["No output file given!\n"] else return ()
       if length output > 1 then usage ["Only one output file allowed!\n"] else return ()

       outputFormat <- return (filter isFormatOut flags)
       if null outputFormat then usage ["No output format given!\n"] else return ()
       if length outputFormat > 1 then usage ["Only one output format allowed!\n"] else return ()
       if checkFormat (head outputFormat) then return () else usage ["Unknown format!\n"]
       formatOut <- return $ getFormat (head outputFormat)

       startup (head input) (head output) formatOut
       return ()

checkFormat :: Flag -> Bool
checkFormat (Format f) = f == "xml" || f == "binary"
checkFormat _ = error "Internal error!"

getFormat :: Flag -> Format
getFormat (Format "xml") = Xml
getFormat (Format "binary") = Binary
getFormat _ = error "Internal error!"

isInput :: Flag -> Bool
isInput (Index _) = True
isInput (Documents _) = True
isInput _ = False

isOutput :: Flag -> Bool
isOutput (Output _) = True
isOutput _ = False

isFormatOut :: Flag -> Bool
isFormatOut (Format _) = True
isFormatOut _ = False

-- | Decide between hybrid and inverted and then fire up!
startup :: Flag -> Flag -> Format -> IO ()
startup (Index inp) (Output out) Binary = do
                                          idx <- (loadFromFile inp) :: IO InvIndex
                                          return (rnf idx)
                                          writeToBinFile out idx
                                          exitWith ExitSuccess
startup (Documents inp) (Output out) Binary = do
                                              doc <- (loadFromFile inp) :: IO Documents
                                              return (rnf doc)
                                              writeToBinFile out doc
                                              exitWith ExitSuccess
startup (Index inp) (Output out) Xml = do
                                       idx <- (loadFromFile inp) :: IO InvIndex
                                       return (rnf idx)
                                       writeToXmlFile out idx
                                       exitWith ExitSuccess
startup (Documents inp) (Output out) Xml = do
                                           doc <- (loadFromFile inp) :: IO Documents
                                           return (rnf doc)
                                           writeToXmlFile out doc
                                           exitWith ExitSuccess
startup _ _ _ = do
                usage ["Internal error!\n"]

usage :: [String] -> IO a
usage errs = if null errs then do
             hPutStrLn stdout use
             exitWith ExitSuccess
             else do
             hPutStrLn stderr (concat errs ++ "\n" ++ use)
             exitWith (ExitFailure (-1))
  where
  header = "Convert - Convert indexes between various types and formats.\n\n" ++
           "Usage: Convert [OPTIONS] where FORMAT is one of the following:\n\n" ++
           "binary - For binary files\n" ++
           "xml - For XML files\n\n" ++
           "Avaliable options:" 
  use    = usageInfo header options

commandLineOpts :: [String] -> IO [Flag]
commandLineOpts argv = case getOpt Permute options argv of
                       (o, [], []  ) -> return o
                       (_, _, errs) -> usage errs

options :: [OptDescr Flag]
options = [ Option "i" ["index"] (ReqArg Index "FILE") "Loads index from FILE"
          , Option "d" ["documents"] (ReqArg Documents "FILE") "Loads documents from FILE"
          , Option "f" ["format"] (ReqArg Format "FORMAT") "Specifies the format of the output file"
          , Option "o" ["output"] (ReqArg Output "FILE") "Write converted data to FILE"
          , Option ['V'] ["version"]  (NoArg Version)     "Output version and exit"
          , Option ['?'] ["help"]  (NoArg Help)     "Output this help and exit"
          ]
