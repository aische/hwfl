module Main where

import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Pretty (prettyModuleBody)
import Hwfl.Ast.Module (LoadedModule (lmBody))
import Hwfl.Cli.Args
  ( RunFlags (..),
    flagProviderSet,
    parseApprove,
    parseCheckFlags,
    parseChoose,
    parseExtend,
    parseReply,
    parseRunFlags,
    parseShow,
    parseWsRun,
    wantsJson,
  )
import Hwfl.Cli.Json
  ( jsonDriverError,
    jsonPlainError,
    jsonRuntimeError,
    jsonUsageError,
    renderCliError,
  )
import Hwfl.Exception (describeException, trySync)
import Hwfl.Driver
  ( DriverError (..),
    DriverRunRequest (..),
    Observer,
    RunOutcome (..),
    ShowMode (..),
    defaultDriverRunRequest,
    driverApprove,
    driverCheck,
    driverChoose,
    driverExtendAgent,
    driverReply,
    driverResume,
    driverRun,
    driverShow,
    driverStep,
    noopObserver,
    renderDriverError,
    stderrDebugObserver,
    storeRunId,
  )
import Hwfl.Env (loadDotenv)
import Hwfl.Eval.Value (renderValue)
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Simple (mkSimpleProvider)
import Hwfl.Obs.Show (showStore)
import Hwfl.Parse.Load (loadModule)
import Hwfl.Runtime.Error (RuntimeError, renderRuntimeError, runtimeExitCode)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine
  ( AgentExhaustedRequest (..),
    AskRequest (..),
    ChoiceRequest (..),
    ConfirmRequest (..),
    MachineStatus (..),
    PauseReason (..),
  )
import Hwfl.Runtime.Run (parseCliInputs)
import Hwfl.Runtime.Store (RunStore)
import Hwfl.Source (renderDiagnostics)
import System.Directory (getCurrentDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, hIsTerminalDevice, hPutStrLn, stdin, stderr)
import System.IO.Error (isEOFError)

main :: IO ()
main = do
  args <- getArgs
  outcome <- trySync (loadDotenv >> dispatch args)
  case outcome of
    Right () -> pure ()
    Left ex -> do
      -- Last resort: the run loop contains its own crashes, so reaching here
      -- means loading, the CLI itself, or reporting threw. Still emit the
      -- normal error shape rather than a raw GHC exception.
      reportPlainFailure
        (wantsJson args)
        1
        "internal"
        "InternalError"
        (describeException ex)
      exitWith (ExitFailure 1)

dispatch :: [String] -> IO ()
dispatch = \case
  ["parse", path] -> cmdParse path
  ("check" : rest) -> cmdCheck rest
  ["version"] -> putStrLn "hwfl 0.1.0.0"
  ("run" : rest) -> cmdRun rest
  ("step" : rest) -> cmdStep rest
  ("resume" : rest) -> cmdResume rest
  ("approve" : rest) -> cmdApprove rest
  ("choose" : rest) -> cmdChoose rest
  ("reply" : rest) -> cmdReply rest
  ("extend" : rest) -> cmdExtend rest
  ("show" : rest) -> cmdShow rest
  _ -> usage

usage :: IO ()
usage = do
  hPutStrLn
    stderr
    "usage: hwfl parse|check <project|module.md> | hwfl run <project|module.md> [options]"
  hPutStrLn
    stderr
    "       hwfl step|resume <workspace> <run-id> [--llm-provider mock|simple] [--dump]"
  hPutStrLn
    stderr
    "       hwfl approve <workspace> <run-id> --yes|--no [--llm-provider mock|simple] [--dump]"
  hPutStrLn
    stderr
    "       hwfl choose <workspace> <run-id> --select <option> [--llm-provider mock|simple] [--dump]"
  hPutStrLn
    stderr
    "       hwfl reply <workspace> <run-id> --text <string> [--llm-provider mock|simple] [--dump]"
  hPutStrLn
    stderr
    "       hwfl extend <workspace> <run-id> --rounds N [--llm-provider mock|simple] [--dump]"
  hPutStrLn
    stderr
    "       hwfl show <workspace> <run-id> [--tree|--spans|--snapshot] [--filter PREFIX]"
  hPutStrLn
    stderr
    "  run options: --workspace <dir> --input k=v --example <name> --llm-provider mock|simple --no-check --step -v|--verbose --debug --cost --dump --json --interactive"
  hPutStrLn stderr "  check options: --json"
  hPutStrLn stderr "  use -- before dash-prefixed paths (e.g. hwfl check -- -odd.md)"
  exitWith (ExitFailure 2)

reportUsage :: Bool -> String -> IO ()
reportUsage json msg =
  if json
    then TIO.hPutStrLn stderr (renderCliError (jsonUsageError (T.pack msg)))
    else hPutStrLn stderr msg

cmdParse :: FilePath -> IO ()
cmdParse path = do
  result <- loadModule path
  case result of
    Left diags -> do
      TIO.hPutStrLn stderr (renderDiagnostics diags)
      exitWith (ExitFailure 1)
    Right loaded -> TIO.putStrLn (prettyModuleBody (lmBody loaded))

cmdCheck :: [String] -> IO ()
cmdCheck rest = case parseCheckFlags rest of
  Left msg -> do
    reportUsage (wantsJson rest) msg
    exitWith (ExitFailure 2)
  Right (path, json) -> do
    result <- driverCheck path
    case result of
      Left err -> do
        reportDriverFailure json err
        exitWith (ExitFailure 1)
      Right _ -> pure ()

reportDriverFailure :: Bool -> DriverError -> IO ()
reportDriverFailure json err =
  if json
    then TIO.hPutStrLn stderr (renderCliError (jsonDriverError err))
    else TIO.hPutStrLn stderr (renderDriverError err)

reportPlainFailure :: Bool -> Int -> Text -> Text -> Text -> IO ()
reportPlainFailure json exitCode category kind msg =
  if json
    then TIO.hPutStrLn stderr (renderCliError (jsonPlainError exitCode category kind msg))
    else TIO.hPutStrLn stderr msg

reportRuntimeFailure :: Bool -> Int -> RuntimeError -> IO ()
reportRuntimeFailure json exitCode err =
  if json
    then TIO.hPutStrLn stderr (renderCliError (jsonRuntimeError exitCode err))
    else TIO.hPutStrLn stderr (renderRuntimeError err)

cmdRun :: [String] -> IO ()
cmdRun rest = case parseRunFlags rest of
  Left msg -> do
    reportUsage (wantsJson rest) msg
    exitWith (ExitFailure 2)
  Right flags0 -> do
    let json = flags0.rfJson
    envProv <- lookupEnv "HWFL_LLM_PROVIDER"
    let flags =
          case (flagProviderSet rest, envProv) of
            (True, _) -> flags0
            (False, Just p) -> flags0 {rfProvider = p}
            (False, Nothing) -> flags0
    when flags.rfInteractive $ do
      when flags.rfJson $ do
        reportUsage False "--interactive is incompatible with --json"
        exitWith (ExitFailure 2)
      tty <- hIsTerminalDevice stdin
      unless tty $ do
        hPutStrLn stderr "hwfl run: --interactive requires a TTY stdin"
        exitWith (ExitFailure 2)
    cwd <- getCurrentDirectory
    let ws = fromMaybe cwd flags.rfWorkspace
    inputs <- case parseCliInputs flags.rfInputs of
      Left err -> do
        reportRuntimeFailure json 2 err
        exitWith (ExitFailure 2)
      Right is -> pure is
    provider <- resolveProvider json flags.rfProvider flags.rfCatalog flags.rfDump
    unless (flags.rfNoCheck || json) $
      hPutStrLn stderr "hwfl run: checking…"
    let observer =
          if flags.rfDebug then stderrDebugObserver else noopObserver
        req =
          (defaultDriverRunRequest flags.rfModule ws provider)
            { drrInputs = inputs,
              drrExample = T.pack <$> flags.rfExample,
              drrSkipCheck = flags.rfNoCheck,
              drrModelCatalog = flags.rfCatalog,
              drrMode = if flags.rfStep then StepOnce else StepRun,
              drrObserver = observer,
              drrCost = flags.rfCost
            }
    result <- driverRun req
    case result of
      Left err -> do
        reportDriverFailure json err
        exitWith (ExitFailure 1)
      Right outcome ->
        if flags.rfInteractive
          then
            handleOutcomeInteractive
              (flags.rfVerbose || flags.rfDebug)
              ws
              provider
              flags.rfCatalog
              observer
              outcome
          else handleOutcome json (flags.rfVerbose || flags.rfDebug) outcome

cmdStep :: [String] -> IO ()
cmdStep args = case parseWsRun args of
  Left msg -> dieUsage msg
  Right (ws, runId, provName, catalog, dump) -> do
    provider <- resolveProvider False provName catalog dump
    handleOutcome False False =<< driverStep ws runId provider catalog noopObserver

cmdResume :: [String] -> IO ()
cmdResume args = case parseWsRun args of
  Left msg -> dieUsage msg
  Right (ws, runId, provName, catalog, dump) -> do
    provider <- resolveProvider False provName catalog dump
    handleOutcome False False =<< driverResume ws runId provider catalog noopObserver

cmdApprove :: [String] -> IO ()
cmdApprove args = case parseApprove args of
  Left msg -> dieUsage msg
  Right (ws, runId, yes, provName, catalog, dump) -> do
    provider <- resolveProvider False provName catalog dump
    handleOutcome False False =<< driverApprove ws runId yes provider catalog noopObserver

cmdChoose :: [String] -> IO ()
cmdChoose args = case parseChoose args of
  Left msg -> dieUsage msg
  Right (ws, runId, selected, provName, catalog, dump) -> do
    provider <- resolveProvider False provName catalog dump
    handleOutcome False False =<< driverChoose ws runId selected provider catalog noopObserver

cmdReply :: [String] -> IO ()
cmdReply args = case parseReply args of
  Left msg -> dieUsage msg
  Right (ws, runId, text, provName, catalog, dump) -> do
    provider <- resolveProvider False provName catalog dump
    handleOutcome False False =<< driverReply ws runId text provider catalog noopObserver

cmdExtend :: [String] -> IO ()
cmdExtend args = case parseExtend args of
  Left msg -> dieUsage msg
  Right (ws, runId, extra, provName, catalog, dump) -> do
    provider <- resolveProvider False provName catalog dump
    handleOutcome False False =<< driverExtendAgent ws runId extra provider catalog noopObserver

cmdShow :: [String] -> IO ()
cmdShow args = case parseShow args of
  Left msg -> dieUsage msg
  Right opts -> do
    result <- driverShow opts
    case result of
      Left err -> do
        TIO.hPutStrLn stderr err
        exitWith (ExitFailure 1)
      Right txt -> TIO.putStrLn txt

handleOutcome :: Bool -> Bool -> RunOutcome -> IO ()
handleOutcome json showTrace = \case
  OutcomeCompleted val store _ -> do
    case renderValue val of
      Left msg -> do
        reportPlainFailure json 1 "runtime" "RenderError" ("result render failed: " <> msg)
        print val
      Right t -> TIO.putStrLn t
    dumpTrace showTrace store
  OutcomePaused _ msg store _ -> do
    reportPlainFailure json 3 "runtime" "Paused" msg
    dumpTrace showTrace store
    exitWith (ExitFailure 3)
  OutcomeFailed err store _ -> do
    reportRuntimeFailure json (runtimeExitCode err) err
    dumpTrace showTrace store
    exitWith (exitFor err)

-- | Like 'handleOutcome', but on human gates prompt stdin and call the same
-- resolve APIs as @approve@ / @choose@ / @reply@ until the run finishes.
handleOutcomeInteractive ::
  Bool ->
  FilePath ->
  LlmProvider ->
  FilePath ->
  Observer ->
  RunOutcome ->
  IO ()
handleOutcomeInteractive showTrace ws provider catalog observer = go
  where
    go = \case
      OutcomeCompleted val store _ -> do
        case renderValue val of
          Left msg -> do
            reportPlainFailure False 1 "runtime" "RenderError" ("result render failed: " <> msg)
            print val
          Right t -> TIO.putStrLn t
        dumpTrace showTrace store
      OutcomeFailed err store _ -> do
        reportRuntimeFailure False (runtimeExitCode err) err
        dumpTrace showTrace store
        exitWith (exitFor err)
      OutcomePaused status msg store _ -> case status of
        MsPaused (PauseAwaitingConfirm c) -> do
          TIO.hPutStrLn stderr msg
          yes <- promptConfirm c
          go =<< driverApprove ws (storeRunId store) yes provider catalog observer
        MsPaused (PauseAwaitingChoice c) -> do
          TIO.hPutStrLn stderr msg
          selected <- promptChoice c
          go =<< driverChoose ws (storeRunId store) selected provider catalog observer
        MsPaused (PauseAwaitingAsk a) -> do
          text <- promptAsk a
          go =<< driverReply ws (storeRunId store) text provider catalog observer
        MsPaused (PauseAwaitingAgent r) -> do
          TIO.hPutStrLn stderr msg
          extra <- promptExtend r
          go =<< driverExtendAgent ws (storeRunId store) extra provider catalog observer
        _ -> do
          reportPlainFailure False 3 "runtime" "Paused" msg
          dumpTrace showTrace store
          exitWith (ExitFailure 3)

promptConfirm :: ConfirmRequest -> IO Bool
promptConfirm c = do
  unless (T.null c.crDetail) $ TIO.hPutStrLn stderr c.crDetail
  loop
  where
    loop = do
      TIO.hPutStr stderr "Approve? [y/n]: "
      hFlush stderr
      line <- readStdinLine
      case T.toLower (T.strip line) of
        "y" -> pure True
        "yes" -> pure True
        "n" -> pure False
        "no" -> pure False
        _ -> do
          hPutStrLn stderr "Please answer y or n."
          loop

promptChoice :: ChoiceRequest -> IO Text
promptChoice c = do
  unless (T.null c.chDetail) $ TIO.hPutStrLn stderr c.chDetail
  mapM_ (\o -> TIO.hPutStrLn stderr ("  - " <> o)) c.chOptions
  loop
  where
    loop = do
      TIO.hPutStr stderr "Select: "
      hFlush stderr
      line <- T.strip <$> readStdinLine
      if line `elem` c.chOptions
        then pure line
        else do
          hPutStrLn stderr "Not a valid option."
          loop

promptAsk :: AskRequest -> IO Text
promptAsk a = do
  unless (T.null a.askDetail) $ TIO.hPutStrLn stderr a.askDetail
  let prompt =
        if T.null a.askPrompt
          then "> "
          else a.askPrompt <> " "
  TIO.hPutStr stderr prompt
  hFlush stderr
  T.strip <$> readStdinLine

promptExtend :: AgentExhaustedRequest -> IO Int
promptExtend r = do
  TIO.hPutStrLn stderr
    ( "Agent exhausted "
        <> T.pack (show r.aerRoundsUsed)
        <> " of "
        <> T.pack (show r.aerRoundsBudget)
        <> " rounds. Enter extra rounds to add (suggested: "
        <> T.pack (show r.aerSuggestedExtra)
        <> "):"
    )
  loop
  where
    loop = do
      TIO.hPutStr stderr "Extra rounds: "
      hFlush stderr
      line <- T.strip <$> readStdinLine
      case reads (T.unpack line) of
        [(n, "")] | n > 0 -> pure n
        _ -> do
          hPutStrLn stderr "Please enter a positive integer."
          loop

readStdinLine :: IO Text
readStdinLine =
  TIO.hGetLine stdin `catch` \e ->
    if isEOFError (e :: IOException)
      then do
        hPutStrLn stderr "hwfl: EOF on stdin"
        exitWith (ExitFailure 2)
      else ioError e

dumpTrace :: Bool -> RunStore -> IO ()
dumpTrace False _ = pure ()
dumpTrace True store = do
  hPutStrLn stderr "hwfl: span tree"
  shown <- showStore store ShowTree Nothing
  case shown of
    Left err -> TIO.hPutStrLn stderr err
    Right txt -> TIO.hPutStrLn stderr txt

exitFor :: RuntimeError -> ExitCode
exitFor err = ExitFailure (runtimeExitCode err)

dieUsage :: String -> IO ()
dieUsage msg = do
  hPutStrLn stderr msg
  exitWith (ExitFailure 2)

resolveProvider :: Bool -> String -> FilePath -> Bool -> IO LlmProvider
resolveProvider json name catalog dump = case name of
  "mock" -> pure mockProvider
  "simple" -> do
    ep <- mkSimpleProvider dump catalog
    case ep of
      Left err -> do
        reportPlainFailure json 2 "config" "ProviderError" err
        exitWith (ExitFailure 2)
      Right p -> pure p
  other -> do
    reportPlainFailure json 2 "usage" "UnknownProvider" ("unknown --llm-provider: " <> T.pack other <> " (use mock|simple)")
    exitWith (ExitFailure 2)
