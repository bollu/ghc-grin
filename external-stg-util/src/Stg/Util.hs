module Stg.Util
    ( -- * Convenient IO
      readDump, readDump',
      readDumpInfo
    ) where

import Prelude hiding (readFile)

import qualified Data.ByteString.Lazy as BSL
import Data.Binary
import Data.Binary.Get

import Stg.Syntax
import Stg.Reconstruct

readDump' :: FilePath -> IO SModule
readDump' fname = decode <$> BSL.readFile fname

readDump :: FilePath -> IO Module
readDump fname = reconModule <$> readDump' fname

readDumpInfo :: FilePath -> IO (Name, UnitId, ModuleName, [(UnitId, [ModuleName])])
readDumpInfo fname = decode <$> BSL.readFile fname
