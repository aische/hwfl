-- | Execute / step / resume / approve a loaded module under a host environment.
module Pml.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
    stepRun,
    resumeRun,
    approveRun,
    loadRunEnv,
    parseCliInputs,
    projectHashOf,
    newRunId,
  )
where

import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Pml.Ast.Decl (Decl (..), ModuleBody (..))
import Pml.Ast.Module (LoadedModule (..), Section (..))
import Pml.Ast.Name (Ident (..), Slug)
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Prelude (preludeEnv)
import Pml.Eval.Pure (bindParams)
import Pml.Eval.Value
import Pml.Llm.Provider (LlmProvider)
import Pml.Parse.Load (loadModule)
import Pml.Runtime.Error (RuntimeError (..))
import Pml.Runtime.Eval
  ( RunCtx (..),
    StepMode (..),
    approveMachine,
    runUntilPause,
  )
import Pml.Runtime.Host (HostEnv (..), hostOpsEnv)
import Pml.Runtime.Machine
import Pml.Runtime.Snapshot
import Pml.Runtime.Workspace (newWorkspace, workspaceRoot)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

data RunOptions = RunOptions
  { roWorkspace :: FilePath,
    roProvider :: LlmProvider,
    roInputs :: [(Ident, Value)],
    roRunId :: Maybe Text,
    roEntry :: FilePath,
    roMode :: StepMode
  }

data RunOutcome
  = OutcomeCompleted Value RunStore Int
  | OutcomePaused MachineStatus Text RunStore Int
  | OutcomeFailed RuntimeError RunStore Int
  deriving stock (Show)

loadRunEnv :: ModuleBody -> (Env, FunTable)
loadRunEnv (ModuleBody decls _) =
  let funs = [(n, ps, body) | DFun n ps _ body <- decls]
      table = Map.fromList [(n, (ps, body)) | (n, ps, body) <- funs]
      env =
        Map.union
          (Map.fromList [(n, VTopFun n) | (n, _, _) <- funs])
          (Map.union hostOpsEnv preludeEnv)
   in (env, table)

sectionMap :: LoadedModule -> Map Slug Text
sectionMap loaded =
  Map.fromList
    [(secSlug s, secBody s) | s <- lmSections loaded]

runLoadedModule :: RunOptions -> LoadedModule -> IO RunOutcome
runLoadedModule opts loaded = do
  ws <- newWorkspace opts.roWorkspace
  runId <- maybe newRunId pure opts.roRunId
  let hash = projectHashOf loaded
  store <- openRunStore (workspaceRoot ws) runId
  now <- getCurrentTime
  let started = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
  writeRunMeta
    store
    RunMeta
      { rmRunId = runId,
        rmProjectHash = hash,
        rmEntry = opts.roEntry,
        rmStartedAt = started,
        rmStatus = "running"
      }
  seqRef <- newIORef (0 :: Int)
  let (baseEnv, funs) = loadRunEnv (lmBody loaded)
      host =
        HostEnv
          { heWorkspace = ws,
            heProvider = opts.roProvider,
            heLog = \msg -> hPutStrLn stderr (T.unpack msg)
          }
      ctx =
        RunCtx
          { rcHost = host,
            rcSections = sectionMap loaded,
            rcFuns = funs,
            rcBaseEnv = baseEnv,
            rcStore = store,
            rcProjectHash = hash,
            rcSeq = seqRef
          }
  hPutStrLn stderr ("pml run: run_id=" <> T.unpack runId)
  case startMain funs baseEnv opts.roInputs of
    Left err -> do
      let m0 = initialMachine hash (CurReturn VUnit)
          m =
            m0
              { mStatus = MsFailed,
                mError = Just err
              }
      persistTransition store seqRef hash Nothing Nothing MsFailed (Just m)
      pure (OutcomeFailed err store 0)
    Right current -> do
      let m0 = initialMachine hash current
      m1 <- runUntilPause ctx opts.roMode m0
      seqNo <- readIORef seqRef
      finalizeOutcome store seqNo m1

startMain :: FunTable -> Env -> [(Ident, Value)] -> Either RuntimeError Current
startMain funs env inputs = case Map.lookup (Ident "main") funs of
  Nothing -> Left (EvalErr (Trap "unknown function: main"))
  Just (params, body) ->
    let arg = case inputs of
          [] -> VUnit
          _ -> VRecord inputs
     in case bindParams params [(Nothing, arg)] of
          Left e -> Left (EvalErr e)
          Right binds -> Right (CurEval body (extendEnvMany binds env))

finalizeOutcome :: RunStore -> Int -> Machine -> IO RunOutcome
finalizeOutcome store seqNo m = case m.mStatus of
  MsCompleted ->
    pure (OutcomeCompleted (maybe VUnit id m.mLastResult) store seqNo)
  MsFailed ->
    pure
      ( OutcomeFailed
          (maybe (EvalErr (Trap "failed")) id m.mError)
          store
          seqNo
      )
  MsPaused reason ->
    pure (OutcomePaused m.mStatus (pauseMessage reason) store seqNo)
  other ->
    pure
      ( OutcomeFailed
          (EvalErr (Trap ("unexpected status: " <> T.pack (show other))))
          store
          seqNo
      )

pauseMessage :: PauseReason -> Text
pauseMessage = \case
  PauseExplicit -> "paused after step"
  PauseAwaitingConfirm c -> "awaiting confirm: " <> c.crTitle
  PauseCrashRecovery -> "paused (crash recovery)"

mkCtx ::
  LlmProvider ->
  FilePath ->
  LoadedModule ->
  RunStore ->
  Text ->
  IORef Int ->
  IO RunCtx
mkCtx provider wsRoot loaded store hash seqRef = do
  ws <- newWorkspace wsRoot
  let (baseEnv, funs) = loadRunEnv (lmBody loaded)
      host =
        HostEnv
          { heWorkspace = ws,
            heProvider = provider,
            heLog = \msg -> hPutStrLn stderr (T.unpack msg)
          }
  pure
    RunCtx
      { rcHost = host,
        rcSections = sectionMap loaded,
        rcFuns = funs,
        rcBaseEnv = baseEnv,
        rcStore = store,
        rcProjectHash = hash,
        rcSeq = seqRef
      }

loadExisting ::
  FilePath ->
  Text ->
  LlmProvider ->
  IO (Either RuntimeError (RunCtx, Machine, RunStore, IORef Int))
loadExisting workspace runId provider = do
  store <- openRunStore workspace runId
  mMeta <- readRunMeta store
  mSnap <- readRunSnapshot store
  case (mMeta, mSnap) of
    (Just meta, Just snap) -> case snap.rsMachine of
      Nothing -> pure (Left (ConfigErr "snapshot has no machine_json"))
      Just machine -> do
        loadedE <- loadModule meta.rmEntry
        case loadedE of
          Left diags ->
            pure (Left (ConfigErr ("cannot reload entry: " <> T.pack (show diags))))
          Right loaded -> do
            let hash = projectHashOf loaded
            if hash /= snap.rsProjectHash
              then pure (Left (ConfigErr "stale project: hash mismatch"))
              else do
                seqRef <- newIORef snap.rsSeq
                ctx <- mkCtx provider workspace loaded store hash seqRef
                pure (Right (ctx, machine, store, seqRef))
    _ -> pure (Left (ConfigErr "missing meta.json or snapshot.json"))

stepRun :: FilePath -> Text -> LlmProvider -> IO RunOutcome
stepRun workspace runId provider = do
  loaded <- loadExisting workspace runId provider
  case loaded of
    Left e -> failed store0 e
    Right (ctx, machine0, store, seqRef) ->
      case machine0.mStatus of
        MsPaused (PauseAwaitingConfirm _) -> do
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo machine0
        _ -> do
          let machine = unpauseExplicit machine0
          m1 <- runUntilPause ctx StepOnce machine
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo m1
  where
    store0 = RunStore (workspace </> ".pml" </> "runs" </> T.unpack runId) runId
    failed store e = pure (OutcomeFailed e store 0)

resumeRun :: FilePath -> Text -> LlmProvider -> IO RunOutcome
resumeRun workspace runId provider = do
  loaded <- loadExisting workspace runId provider
  case loaded of
    Left e -> pure (OutcomeFailed e store0 0)
    Right (ctx, machine0, store, seqRef) ->
      case machine0.mStatus of
        MsPaused (PauseAwaitingConfirm _) -> do
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo machine0
        MsCompleted -> do
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo machine0
        MsFailed -> do
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo machine0
        _ -> do
          let machine = unpauseExplicit machine0
          m1 <- runUntilPause ctx StepRun machine
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo m1
  where
    store0 = RunStore (workspace </> ".pml" </> "runs" </> T.unpack runId) runId

approveRun :: FilePath -> Text -> Bool -> LlmProvider -> IO RunOutcome
approveRun workspace runId yes provider = do
  loaded <- loadExisting workspace runId provider
  case loaded of
    Left e -> pure (OutcomeFailed e store0 0)
    Right (ctx, machine0, store, seqRef) ->
      case approveMachine yes machine0 of
        Left e -> pure (OutcomeFailed e store 0)
        Right machine1 -> do
          persistTransition
            store
            seqRef
            ctx.rcProjectHash
            (Just HostHumanConfirm)
            (Just (VBool yes))
            machine1.mStatus
            (Just machine1)
          m2 <- runUntilPause ctx StepRun machine1
          seqNo <- readIORef seqRef
          finalizeOutcome store seqNo m2
  where
    store0 = RunStore (workspace </> ".pml" </> "runs" </> T.unpack runId) runId

unpauseExplicit :: Machine -> Machine
unpauseExplicit m = case m.mStatus of
  MsPaused PauseExplicit -> m {mStatus = MsRunning}
  _ -> m

parseCliInputs :: [String] -> Either RuntimeError [(Ident, Value)]
parseCliInputs = traverse parseOne
  where
    parseOne s = case break (== '=') s of
      (k, '=' : v)
        | not (null k) -> Right (Ident (T.pack k), coerceInput v)
      _ -> Left (ConfigErr ("invalid --input (expected k=v): " <> T.pack s))

coerceInput :: String -> Value
coerceInput s = case s of
  "true" -> VBool True
  "false" -> VBool False
  _
    | all (`elem` ('-' : ['0' .. '9'])) s,
      not (null s),
      s /= "-",
      Just _ <- readMaybeInt s ->
        VInt (read s)
    | otherwise -> VString (T.pack s)

readMaybeInt :: String -> Maybe Integer
readMaybeInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing

projectHashOf :: LoadedModule -> Text
projectHashOf loaded =
  let payload =
        T.pack (lmPath loaded)
          <> "\n"
          <> T.pack (show (lmFrontmatter loaded))
          <> "\n"
          <> T.pack (show (lmBody loaded))
   in T.pack (show (T.foldl' (\h c -> h * 33 + fromEnum c) (0 :: Int) payload))

newRunId :: IO Text
newRunId = do
  now <- getCurrentTime
  pure ("run-" <> T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now))
