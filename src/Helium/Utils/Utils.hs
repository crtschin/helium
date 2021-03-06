{-| Module      :  Utils
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable

	Some Prelude-like functions
-}

module Helium.Utils.Utils where

import Data.IORef

import GHC.IO (unsafePerformIO)
import System.IO (withFile, hGetContents, IOMode(..), hSetBinaryMode)
import Data.List (group, groupBy, sort, elemIndex)
import qualified Control.Exception as CE (catch, IOException, evaluate)
import System.FilePath
import Helium.Utils.Logger

-- | Concrete representation of holes
hole :: String
hole = "?"

-------------------------------------------------------
-- String utils
-------------------------------------------------------
ltrim :: String -> String
ltrim (' ':xs) = ltrim xs
ltrim xs       = xs

rtrim :: String -> String
rtrim = reverse . ltrim . reverse

trim :: String -> String
trim = ltrim . rtrim

commaList :: [String] -> String
commaList [] = ""
commaList [x] = x
commaList (x:xs) = x ++ ", " ++ commaList xs

-------------------------------------------------------
-- Tuples
-------------------------------------------------------
                
fst3 :: (a, b, c) -> a
fst3 (a,_,_)   = a

snd3 :: (a, b, c) -> b
snd3 (_,a,_)   = a

thd3 :: (a, b, c) -> c
thd3 (_,_,a)   = a

fst4 :: (a, b, c, d) -> a
fst4 (a,_,_,_) = a

snd4 :: (a, b, c, d) -> b
snd4 (_,a,_,_) = a

thd4 :: (a, b, c, d) -> c
thd4 (_,_,a,_) = a

fth4 :: (a, b, c, d) -> d
fth4 (_,_,_,a) = a

-------------------------------------------------------

throw :: String -> IO a
throw = ioError . userError

groupAll :: Ord a => [a] -> [[a]]
groupAll = group.sort

groupAllBy :: Ord a => (a -> a -> Bool) -> [a] -> [[a]]
groupAllBy eq = groupBy eq.sort

{-- Just for renaming elemIndex to a more usual name -}
indexOf :: Eq a => a -> [a] -> Maybe Int
indexOf = elemIndex

{--- Returns the index of the last occurrence of the given element in the given list -}
lastIndexOf :: Eq a => a -> [a] -> Maybe Int
lastIndexOf x xs =
    case indexOf x (reverse xs) of    
        Nothing     ->  Nothing
        Just idx    ->  Just (length xs - idx - 1)
   
combinePathAndFile :: String -> String -> String
combinePathAndFile path file =
    case path of 
        "" -> file
        _  -> path ++ [pathSeparator] ++ file
        
-- Split file name
-- e.g. /docs/haskell/Hello.hs =>
--   filePath = /docs/haskell  baseName = Hello  ext = hs
-- IMPORTANT!!! There is one more copy of splitFilePath in texthint and a similar function in LoggerEnabled
splitFilePath :: String -> (String, String, String)
splitFilePath filePath = 
    let slashes = "\\/"
        (revFileName, revPath) = span (`notElem` slashes) (reverse filePath)
        (baseName, ext)  = span (/= '.') (reverse revFileName)
    in (reverse revPath, baseName, dropWhile (== '.') ext)
    
-- unsafePerformIO only to be able to make an error report 
-- in case of an internal error
refToCurrentFileName :: IORef String
refToCurrentFileName = unsafePerformIO (newIORef "<no module>")

-- unsafePerformIO only to  be able to make an error report 
-- in case of an internal error
refToCurrentImported :: IORef [String]
refToCurrentImported = unsafePerformIO (newIORef [])
   
internalError :: String -> String -> String -> a
internalError moduleName functionName message = unsafePerformIO $ do
   action `CE.catch` handler
   return . error . unlines $
           [ ""
           , "INTERNAL ERROR - " ++ message
           , "** Module   : " ++ moduleName
           , "** Function : " ++ functionName
           ]
 where
   handler :: CE.IOException -> IO () 
   handler _ = return ()

   action :: IO ()
   action = do -- internal errors are automatically logged
      curFileName <- readIORef refToCurrentFileName
      curImports  <- readIORef refToCurrentImported       
      logInternalError (Just (curImports,curFileName)) {- no debugging, we can't get to the command-line option DebugLogger here -}

readSourceFile :: String -> IO String
readSourceFile fullName = 
    CE.catch (
    withFile fullName ReadMode $ \h1 -> do               
         hSetBinaryMode h1 True
         contents <- hGetContents h1
         -- Without evaluate everything breaks down.
         src <- CE.evaluate contents
         _ <- CE.evaluate (length src) -- For some reason I need to put this here too. Don't know why.
         return src)
    (\ioErr -> 
         let message = "Unable to read file " ++ show fullName 
                    ++ " (" ++ show (ioErr :: CE.IOException) ++ ")"
         in throw message)
         
maxInt, minInt :: Integer
maxInt = 1073741823
minInt = -1073741823
