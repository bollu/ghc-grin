module Main where

import Control.Monad

import System.Environment
import System.Exit
import qualified Text.Megaparsec as M

import Lambda.Syntax
import Lambda.Parse
import Lambda.Pretty
import Lambda.Lint
import Lambda.GrinCodeGenTyped
import Grin.Pretty
import Pipeline.Pipeline

import Text.PrettyPrint.ANSI.Leijen (ondullblack, plain)

import qualified Data.ByteString as BS
import Data.Store

data Opts
  = Opts
  { inputs :: [FilePath]
  , output :: FilePath
  }

showUsage = do putStrLn "Usage: lambda-grin <source-files> [-o <output-file>]"
               exitWith ExitSuccess

getOpts :: IO Opts
getOpts = do xs <- getArgs
             return $ process (Opts [] "a.out") xs
  where
    process opts ("-o":o:xs) = process (opts { output = o }) xs
    process opts (x:xs) = process (opts { inputs = x:inputs opts }) xs
    process opts [] = opts

cg_main :: Opts -> IO ()
cg_main opts = do
  forM_ (inputs opts) $ \fname -> do
    {-
    content <- readFile fname
    let program = either (error . M.parseErrorPretty' content) id $ parseLambda fname content
    putStrLn "\n* Lambda"
    printLambda program
    let lambdaGrin = codegenGrin program
    void $ pipeline pipelineOpts lambdaGrin
      [ SaveGrin "from-lambda.grin"
      , T GenerateEval
      , SaveGrin (output opts)
      , PrintGrin ondullblack
      ]
    -}
    program <- decodeEx <$> BS.readFile fname :: IO Exp
    lintLambda program
    let lambdaGrin = codegenGrin program
    void $ pipeline pipelineOpts Nothing lambdaGrin
      [ T TrivialCaseElimination
      , T BindNormalisation
      , SaveGrin (Rel $ fname ++ ".grin")
      , SaveBinary (fname ++ ".grin")
      ]

main :: IO ()
main = do opts <- getOpts
          if (null (inputs opts))
             then showUsage
             else cg_main opts

pipelineOpts :: PipelineOpts
pipelineOpts = defaultOpts
  { _poOutputDir = ".lambda"
  , _poFailOnLint = True
  }
