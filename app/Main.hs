module Main where

import Data.Text.IO qualified as TIO
import Pml.Ast.Module (LoadedModule (lmBody))
import Pml.Ast.Pretty (prettyModuleBody)
import Pml.Check.Error (renderCheckError)
import Pml.Check.Module (checkLoadedModule)
import Pml.Parse.Load (loadModule)
import Pml.Source (renderDiagnostics)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)

-- | CLI: @pml parse@ / @pml check@ (single module; project graph deferred).
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
    ["check", path] -> do
      -- M3: check a single module path. Full project.json + import graph
      -- deferred until multi-module workflows need it (same @pml check@ product).
      hPutStrLn stderr "pml check: single-module mode (project graph deferred)"
      result <- loadModule path
      case result of
        Left diags -> do
          TIO.hPutStrLn stderr (renderDiagnostics diags)
          exitWith (ExitFailure 1)
        Right loaded -> case checkLoadedModule loaded of
          Left err -> do
            TIO.hPutStrLn stderr (renderCheckError err)
            exitWith (ExitFailure 1)
          Right _ -> pure ()
    ["version"] -> putStrLn "pml 0.1.0.0"
    _ -> do
      hPutStrLn stderr "usage: pml parse <module.md> | pml check <module.md> | pml version"
      exitWith (ExitFailure 2)
