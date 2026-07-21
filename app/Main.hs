module Main where

import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Pretty (prettyModuleBody)
import Hwfl.Ast.Module (LoadedModule (lmBody))
import Hwfl.Cli.Json
  ( jsonDriverError,
    jsonPlainError,
    jsonRuntimeError,
    jsonUsageError,
    renderCliError,
  )
import Hwfl.Driver
  ( DriverError (..),
    DriverRunRequest (..),
    Observer,
    RunOutcome (..),
    ShowMode (..),
    ShowOptions (..),
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
import Hwfl.Runtime.Error (RuntimeError (..), renderRuntimeError)
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
  loadDotenv
  args <- getArgs
  case args of
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
    "  run options: --workspace <dir> --input k=v --llm-provider mock|simple --no-check --step -v|--verbose --debug --cost --dump --json --interactive"
  hPutStrLn stderr "  check options: --json"
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
    reportUsage ("--json" `elem` rest) msg
    exitWith (ExitFailure 2)
  Right (path, json) -> do
    result <- driverCheck path
    case result of
      Left err -> do
        reportDriverFailure json err
        exitWith (ExitFailure 1)
      Right _ -> pure ()

parseCheckFlags :: [String] -> Either String (FilePath, Bool)
parseCheckFlags = go False Nothing
  where
    go json mPath = \case
      [] -> case mPath of
        Just path -> Right (path, json)
        Nothing -> Left "hwfl check: missing <project|module.md>"
      ("--json" : rest) -> go True mPath rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case mPath of
            Nothing -> go json (Just x) rest
            Just _ -> Left ("unexpected argument: " <> x)

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

data RunFlags = RunFlags
  { rfModule :: FilePath,
    rfWorkspace :: Maybe FilePath,
    rfInputs :: [String],
    rfProvider :: String,
    rfNoCheck :: Bool,
    rfCatalog :: FilePath,
    rfStep :: Bool,
    -- | Print span tree after the run.
    rfVerbose :: Bool,
    -- | Live span open/close on stderr (implies verbose tree dump).
    rfDebug :: Bool,
    -- | Prefix host progress lines with running LLM cost.
    rfCost :: Bool,
    -- | Dump llm-simple request/response JSON under ./dumps.
    rfDump :: Bool,
    -- | Machine-readable diagnostics on stderr for failures.
    rfJson :: Bool,
    -- | Prompt on stdin for human gates (TTY only; incompatible with --json).
    rfInteractive :: Bool
  }

cmdRun :: [String] -> IO ()
cmdRun rest = case parseRunFlags rest of
  Left msg -> do
    reportUsage ("--json" `elem` rest) msg
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
    reportRuntimeFailure json (exitCodeFor err) err
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
        reportRuntimeFailure False (exitCodeFor err) err
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
exitFor err = ExitFailure (exitCodeFor err)

exitCodeFor :: RuntimeError -> Int
exitCodeFor = \case
  ConfigErr t
    | "stale project" `T.isInfixOf` t -> 4
  _ -> 1

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
          rfStep = False,
          rfVerbose = False,
          rfDebug = False,
          rfCost = False,
          rfDump = False,
          rfJson = False,
          rfInteractive = False
        }
    takeModule [] _ = Left "hwfl run: missing <module.md>"
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
      | x == "-v" || x == "--verbose" = takeModule xs f {rfVerbose = True}
      | x == "--debug" = takeModule xs f {rfDebug = True, rfVerbose = True}
      | x == "--cost" = takeModule xs f {rfCost = True}
      | x == "--dump" = takeModule xs f {rfDump = True}
      | x == "--json" = takeModule xs f {rfJson = True}
      | x == "--interactive" = takeModule xs f {rfInteractive = True}
      | "-" `T.isPrefixOf` T.pack x = Left ("unknown flag: " <> x)
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
      | x == "-v" || x == "--verbose" = consumeOpts xs f {rfVerbose = True}
      | x == "--debug" = consumeOpts xs f {rfDebug = True, rfVerbose = True}
      | x == "--cost" = consumeOpts xs f {rfCost = True}
      | x == "--dump" = consumeOpts xs f {rfDump = True}
      | x == "--json" = consumeOpts xs f {rfJson = True}
      | x == "--interactive" = consumeOpts xs f {rfInteractive = True}
      | otherwise = Left ("unexpected argument: " <> x)

parseWsRun :: [String] -> Either String (FilePath, T.Text, String, FilePath, Bool)
parseWsRun = go Nothing Nothing "simple" "model-catalog.json" False
  where
    go mWs mId prov catalog dump = \case
      [] -> case (mWs, mId) of
        (Just ws, Just rid) -> Right (ws, rid, prov, catalog, dump)
        _ -> Left "usage: hwfl step|resume <workspace> <run-id> [options]"
      ("--llm-provider" : p : rest) -> go mWs mId p catalog dump rest
      ("--model-catalog" : c : rest) -> go mWs mId prov c dump rest
      ("--dump" : rest) -> go mWs mId prov catalog True rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId prov catalog dump rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) prov catalog dump rest
            _ -> Left ("unexpected argument: " <> x)

parseApprove :: [String] -> Either String (FilePath, T.Text, Bool, String, FilePath, Bool)
parseApprove = go Nothing Nothing Nothing "simple" "model-catalog.json" False
  where
    go mWs mId mYes prov catalog dump = \case
      [] -> case (mWs, mId, mYes) of
        (Just ws, Just rid, Just yes) -> Right (ws, rid, yes, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl approve needs --yes or --no"
        _ -> Left "usage: hwfl approve <workspace> <run-id> --yes|--no"
      ("--yes" : rest) -> go mWs mId (Just True) prov catalog dump rest
      ("--no" : rest) -> go mWs mId (Just False) prov catalog dump rest
      ("--llm-provider" : p : rest) -> go mWs mId mYes p catalog dump rest
      ("--model-catalog" : c : rest) -> go mWs mId mYes prov c dump rest
      ("--dump" : rest) -> go mWs mId mYes prov catalog True rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mYes prov catalog dump rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mYes prov catalog dump rest
            _ -> Left ("unexpected argument: " <> x)

parseChoose :: [String] -> Either String (FilePath, T.Text, T.Text, String, FilePath, Bool)
parseChoose = go Nothing Nothing Nothing "simple" "model-catalog.json" False
  where
    go mWs mId mSel prov catalog dump = \case
      [] -> case (mWs, mId, mSel) of
        (Just ws, Just rid, Just sel) -> Right (ws, rid, sel, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl choose needs --select <option>"
        _ -> Left "usage: hwfl choose <workspace> <run-id> --select <option>"
      ("--select" : s : rest) -> go mWs mId (Just (T.pack s)) prov catalog dump rest
      ("--llm-provider" : p : rest) -> go mWs mId mSel p catalog dump rest
      ("--model-catalog" : c : rest) -> go mWs mId mSel prov c dump rest
      ("--dump" : rest) -> go mWs mId mSel prov catalog True rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mSel prov catalog dump rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mSel prov catalog dump rest
            _ -> Left ("unexpected argument: " <> x)

parseReply :: [String] -> Either String (FilePath, T.Text, T.Text, String, FilePath, Bool)
parseReply = go Nothing Nothing Nothing "simple" "model-catalog.json" False
  where
    go mWs mId mText prov catalog dump = \case
      [] -> case (mWs, mId, mText) of
        (Just ws, Just rid, Just text) -> Right (ws, rid, text, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl reply needs --text <string>"
        _ -> Left "usage: hwfl reply <workspace> <run-id> --text <string>"
      ("--text" : text : rest) -> go mWs mId (Just (T.pack text)) prov catalog dump rest
      ("--llm-provider" : p : rest) -> go mWs mId mText p catalog dump rest
      ("--model-catalog" : c : rest) -> go mWs mId mText prov c dump rest
      ("--dump" : rest) -> go mWs mId mText prov catalog True rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mText prov catalog dump rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mText prov catalog dump rest
            _ -> Left ("unexpected argument: " <> x)

parseExtend :: [String] -> Either String (FilePath, T.Text, Int, String, FilePath, Bool)
parseExtend = go Nothing Nothing Nothing "simple" "model-catalog.json" False
  where
    go mWs mId mRounds prov catalog dump = \case
      [] -> case (mWs, mId, mRounds) of
        (Just ws, Just rid, Just n) -> Right (ws, rid, n, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl extend needs --rounds N"
        _ -> Left "usage: hwfl extend <workspace> <run-id> --rounds N"
      ("--rounds" : n : rest) -> case reads n of
        [(i, "")] | i > 0 -> go mWs mId (Just i) prov catalog dump rest
        _ -> Left ("--rounds must be a positive integer, got: " <> n)
      ("--llm-provider" : p : rest) -> go mWs mId mRounds p catalog dump rest
      ("--model-catalog" : c : rest) -> go mWs mId mRounds prov c dump rest
      ("--dump" : rest) -> go mWs mId mRounds prov catalog True rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mRounds prov catalog dump rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mRounds prov catalog dump rest
            _ -> Left ("unexpected argument: " <> x)

parseShow :: [String] -> Either String ShowOptions
parseShow = go Nothing Nothing ShowSummary Nothing
  where
    go mWs mId mode filt = \case
      [] -> case (mWs, mId) of
        (Just ws, Just rid) ->
          Right
            ShowOptions
              { soWorkspace = ws,
                soRunId = rid,
                soMode = mode,
                soFilter = filt
              }
        _ -> Left "usage: hwfl show <workspace> <run-id> [--tree|--spans|--snapshot] [--filter PREFIX]"
      ("--tree" : rest) -> go mWs mId ShowTree filt rest
      ("--spans" : rest) -> go mWs mId ShowSpans filt rest
      ("--snapshot" : rest) -> go mWs mId ShowSnapshot filt rest
      ("--filter" : p : rest) -> go mWs mId mode (Just (T.pack p)) rest
      (x : rest)
        | "-" `T.isPrefixOf` T.pack x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mode filt rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mode filt rest
            _ -> Left ("unexpected argument: " <> x)
