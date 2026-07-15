module Main where

import Data.Text.IO qualified as TIO
import Pml.Ast.Module (LoadedModule (lmBody))
import Pml.Ast.Pretty (prettyModuleBody)
import Pml.Parse.Load (loadModule)
import Pml.Source (renderDiagnostics)
import System.Environment (getArgs)
import System.Exit (exitFailure)

-- | M0 smoke CLI: @pml parse <file.md>@ pretty-prints the kernel AST.
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["parse", path] -> do
      result <- loadModule path
      case result of
        Left diags -> do
          TIO.putStrLn (renderDiagnostics diags)
          exitFailure
        Right loaded -> TIO.putStrLn (prettyModuleBody (lmBody loaded))
    _ -> do
      putStrLn "usage: pml parse <module.md>"
      exitFailure
