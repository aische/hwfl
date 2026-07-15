module Main where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Pml.Ast.Module (LoadedModule (lmBody))
import Pml.Ast.Pretty (prettyModuleBody)
import Pml.Check.Error (renderCheckError)
import Pml.Check.Module (checkLoadedModule)
import Pml.Eval.Value (renderValue)
import Pml.Llm.Mock (mockProvider)
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Simple (mkSimpleProvider)
import Pml.Parse.Load (loadModule)
import Pml.Runtime.Error (renderRuntimeError)
import Pml.Runtime.Run
  ( RunOptions (..),
    RunResult (..),
    parseCliInputs,
    runLoadedModule,
  )
import Pml.Source (renderDiagnostics)
import System.Directory (getCurrentDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

-- | CLI: parse / check / run / version.
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["parse", path] -> cmdParse path
    ["check", path] -> cmdCheck path
    ["version"] -> putStrLn "pml 0.1.0.0"
    ("run" : rest) -> cmdRun rest
    _ -> usage

usage :: IO ()
usage = do
  hPutStrLn
    stderr
    "usage: pml parse <module.md> | pml check <module.md> | pml run <module.md> [options] | pml version"
  hPutStrLn
    stderr
    "  run options: --workspace <dir> --input k=v --llm-provider mock|simple --no-check"
  exitWith (ExitFailure 2)

cmdParse :: FilePath -> IO ()
cmdParse path = do
  result <- loadModule path
  case result of
    Left diags -> do
      TIO.putStrLn (renderDiagnostics diags)
      exitFailure
    Right loaded -> TIO.putStrLn (prettyModuleBody (lmBody loaded))

cmdCheck :: FilePath -> IO ()
cmdCheck path = do
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

data RunFlags = RunFlags
  { rfModule :: FilePath,
    rfWorkspace :: Maybe FilePath,
    rfInputs :: [String],
    rfProvider :: String,
    rfNoCheck :: Bool,
    rfCatalog :: FilePath
  }

cmdRun :: [String] -> IO ()
cmdRun rest = case parseRunFlags rest of
  Left msg -> do
    hPutStrLn stderr msg
    exitWith (ExitFailure 2)
  Right flags0 -> do
    envProv <- lookupEnv "PML_LLM_PROVIDER"
    let flags =
          case (flagProviderSet rest, envProv) of
            (True, _) -> flags0
            (False, Just p) -> flags0 {rfProvider = p}
            (False, Nothing) -> flags0 -- default simple (spec §08)
    cwd <- getCurrentDirectory
    let ws = maybe cwd id flags.rfWorkspace
    inputs <- case parseCliInputs flags.rfInputs of
      Left err -> do
        TIO.hPutStrLn stderr (renderRuntimeError err)
        exitWith (ExitFailure 2)
      Right is -> pure is
    provider <- resolveProvider flags.rfProvider flags.rfCatalog
    result <- loadModule flags.rfModule
    case result of
      Left diags -> do
        TIO.hPutStrLn stderr (renderDiagnostics diags)
        exitWith (ExitFailure 1)
      Right loaded -> do
        unless flags.rfNoCheck $ do
          hPutStrLn stderr "pml run: checking module…"
          case checkLoadedModule loaded of
            Left err -> do
              TIO.hPutStrLn stderr (renderCheckError err)
              exitWith (ExitFailure 1)
            Right _ -> pure ()
        let opts =
              RunOptions
                { roWorkspace = ws,
                  roProvider = provider,
                  roInputs = inputs,
                  roRunId = Nothing
                }
        runRes <- runLoadedModule opts loaded
        case runRes of
          Left err -> do
            TIO.hPutStrLn stderr (renderRuntimeError err)
            exitWith (ExitFailure 1)
          Right rr -> case renderValue rr.rrValue of
            Left msg -> do
              hPutStrLn stderr ("result render failed: " <> T.unpack msg)
              -- Still success for the run itself; print Show fallback.
              print rr.rrValue
            Right t -> TIO.putStrLn t

unless :: Bool -> IO () -> IO ()
unless b a = if b then pure () else a

resolveProvider :: String -> FilePath -> IO LlmProvider
resolveProvider name catalog = case name of
  "mock" -> pure mockProvider
  "simple" -> do
    ep <- mkSimpleProvider catalog
    case ep of
      Left err -> do
        hPutStrLn stderr (T.unpack err)
        exitWith (ExitFailure 2)
      Right p -> pure p
  other -> do
    hPutStrLn stderr ("unknown --llm-provider: " <> other <> " (use mock|simple)")
    exitWith (ExitFailure 2)

flagProviderSet :: [String] -> Bool
flagProviderSet = elem "--llm-provider"

parseRunFlags :: [String] -> Either String RunFlags
parseRunFlags args = do
  (modPath, flags) <- takeModule args emptyFlags
  pure flags {rfModule = modPath}
  where
    emptyFlags =
      RunFlags
        { rfModule = "",
          rfWorkspace = Nothing,
          rfInputs = [],
          -- Overridden in cmdRun via PML_LLM_PROVIDER / --llm-provider; placeholder.
          rfProvider = "simple",
          rfNoCheck = False,
          rfCatalog = "model-catalog.json"
        }
    takeModule [] _ = Left "pml run: missing <module.md>"
    takeModule (x : xs) f
      | x == "--workspace" = case xs of
          (d : rest) -> takeModule rest f {rfWorkspace = Just d}
          [] -> Left "--workspace needs a directory"
      | x == "--input" = case xs of
          (kv : rest) -> takeModule rest f {rfInputs = f.rfInputs ++ [kv]}
          [] -> Left "--input needs k=v"
      | x == "--llm-provider" = case xs of
          (p : rest) -> takeModule rest f {rfProvider = p}
          [] -> Left "--llm-provider needs a name"
      | x == "--model-catalog" = case xs of
          (c : rest) -> takeModule rest f {rfCatalog = c}
          [] -> Left "--model-catalog needs a path"
      | x == "--no-check" = takeModule xs f {rfNoCheck = True}
      | "--" `T.isPrefixOf` T.pack x = Left ("unknown flag: " <> x)
      | otherwise = consumeOpts xs f {rfModule = x}
    consumeOpts [] f = Right (f.rfModule, f)
    consumeOpts (x : xs) f
      | x == "--workspace" = case xs of
          (d : rest) -> consumeOpts rest f {rfWorkspace = Just d}
          [] -> Left "--workspace needs a directory"
      | x == "--input" = case xs of
          (kv : rest) -> consumeOpts rest f {rfInputs = f.rfInputs ++ [kv]}
          [] -> Left "--input needs k=v"
      | x == "--llm-provider" = case xs of
          (p : rest) -> consumeOpts rest f {rfProvider = p}
          [] -> Left "--llm-provider needs a name"
      | x == "--model-catalog" = case xs of
          (c : rest) -> consumeOpts rest f {rfCatalog = c}
          [] -> Left "--model-catalog needs a path"
      | x == "--no-check" = consumeOpts xs f {rfNoCheck = True}
      | otherwise = Left ("unexpected argument: " <> x)
