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
import Pml.Runtime.Error (RuntimeError (..), renderRuntimeError)
import Pml.Runtime.Eval (StepMode (..))
import Pml.Runtime.Machine (MachineStatus (..))
import Pml.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    approveRun,
    parseCliInputs,
    resumeRun,
    runLoadedModule,
    stepRun,
  )
import Pml.Source (renderDiagnostics)
import System.Directory (getCurrentDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["parse", path] -> cmdParse path
    ["check", path] -> cmdCheck path
    ["version"] -> putStrLn "pml 0.1.0.0"
    ("run" : rest) -> cmdRun rest
    ("step" : rest) -> cmdStep rest
    ("resume" : rest) -> cmdResume rest
    ("approve" : rest) -> cmdApprove rest
    _ -> usage

usage :: IO ()
usage = do
  hPutStrLn
    stderr
    "usage: pml parse|check <module.md> | pml run <module.md> [options]"
  hPutStrLn
    stderr
    "       pml step|resume <workspace> <run-id> [--llm-provider mock|simple]"
  hPutStrLn
    stderr
    "       pml approve <workspace> <run-id> --yes|--no [--llm-provider mock|simple]"
  hPutStrLn
    stderr
    "  run options: --workspace <dir> --input k=v --llm-provider mock|simple --no-check --step"
  exitWith (ExitFailure 2)

cmdParse :: FilePath -> IO ()
cmdParse path = do
  result <- loadModule path
  case result of
    Left diags -> do
      TIO.hPutStrLn stderr (renderDiagnostics diags)
      exitWith (ExitFailure 1)
    Right loaded -> TIO.putStrLn (prettyModuleBody (lmBody loaded))

cmdCheck :: FilePath -> IO ()
cmdCheck path = do
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
    rfCatalog :: FilePath,
    rfStep :: Bool
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
            (False, Nothing) -> flags0
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
                  roRunId = Nothing,
                  roEntry = flags.rfModule,
                  roMode = if flags.rfStep then StepOnce else StepRun
                }
        outcome <- runLoadedModule opts loaded
        handleOutcome outcome

cmdStep :: [String] -> IO ()
cmdStep args = case parseWsRun args of
  Left msg -> dieUsage msg
  Right (ws, runId, provName, catalog) -> do
    provider <- resolveProvider provName catalog
    handleOutcome =<< stepRun ws runId provider

cmdResume :: [String] -> IO ()
cmdResume args = case parseWsRun args of
  Left msg -> dieUsage msg
  Right (ws, runId, provName, catalog) -> do
    provider <- resolveProvider provName catalog
    handleOutcome =<< resumeRun ws runId provider

cmdApprove :: [String] -> IO ()
cmdApprove args = case parseApprove args of
  Left msg -> dieUsage msg
  Right (ws, runId, yes, provName, catalog) -> do
    provider <- resolveProvider provName catalog
    handleOutcome =<< approveRun ws runId yes provider

handleOutcome :: RunOutcome -> IO ()
handleOutcome = \case
  OutcomeCompleted val _ _ -> case renderValue val of
    Left msg -> do
      hPutStrLn stderr ("result render failed: " <> T.unpack msg)
      print val
    Right t -> TIO.putStrLn t
  OutcomePaused status msg _ _ -> do
    TIO.hPutStrLn stderr msg
    case status of
      MsPaused _ -> exitWith (ExitFailure 3)
      _ -> exitWith (ExitFailure 3)
  OutcomeFailed err _ _ -> do
    TIO.hPutStrLn stderr (renderRuntimeError err)
    exitWith (exitFor err)

exitFor :: RuntimeError -> ExitCode
exitFor = \case
  ConfigErr t
    | "stale project" `T.isInfixOf` t -> ExitFailure 4
  _ -> ExitFailure 1

dieUsage :: String -> IO ()
dieUsage msg = do
  hPutStrLn stderr msg
  exitWith (ExitFailure 2)

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
          rfProvider = "simple",
          rfNoCheck = False,
          rfCatalog = "model-catalog.json",
          rfStep = False
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
      | x == "--step" = takeModule xs f {rfStep = True}
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
      | x == "--step" = consumeOpts xs f {rfStep = True}
      | otherwise = Left ("unexpected argument: " <> x)

parseWsRun :: [String] -> Either String (FilePath, T.Text, String, FilePath)
parseWsRun = go Nothing Nothing "simple" "model-catalog.json"
  where
    go mWs mId prov catalog = \case
      [] -> case (mWs, mId) of
        (Just ws, Just rid) -> Right (ws, rid, prov, catalog)
        _ -> Left "usage: pml step|resume <workspace> <run-id> [options]"
      ("--llm-provider" : p : rest) -> go mWs mId p catalog rest
      ("--model-catalog" : c : rest) -> go mWs mId prov c rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId prov catalog rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) prov catalog rest
            _ -> Left ("unexpected argument: " <> x)

parseApprove :: [String] -> Either String (FilePath, T.Text, Bool, String, FilePath)
parseApprove = go Nothing Nothing Nothing "simple" "model-catalog.json"
  where
    go mWs mId mYes prov catalog = \case
      [] -> case (mWs, mId, mYes) of
        (Just ws, Just rid, Just yes) -> Right (ws, rid, yes, prov, catalog)
        (_, _, Nothing) -> Left "pml approve needs --yes or --no"
        _ -> Left "usage: pml approve <workspace> <run-id> --yes|--no"
      ("--yes" : rest) -> go mWs mId (Just True) prov catalog rest
      ("--no" : rest) -> go mWs mId (Just False) prov catalog rest
      ("--llm-provider" : p : rest) -> go mWs mId mYes p catalog rest
      ("--model-catalog" : c : rest) -> go mWs mId mYes prov c rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mYes prov catalog rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mYes prov catalog rest
            _ -> Left ("unexpected argument: " <> x)
