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

import Data.Aeson (object, (.=))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Pml.Ast.Decl (Decl (..), ModuleBody (..))
import Pml.Ast.Module (Frontmatter (..), LoadedModule (..), Section (..))
import Pml.Ast.Name (Ident (..), Slug, qnameToText)
import Pml.Check.Env (TypeEnv)
import Pml.Check.Infer (inferModuleEnv)
import Pml.Check.Prelude (preludeTypeEnv)
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Prelude (preludeEnv)
import Pml.Eval.Pure (bindParams)
import Pml.Eval.Value
import Pml.Llm.Provider (LlmProvider)
import Pml.Obs.Span (SpanKind (..), SpanStatus (..))
import Pml.Obs.Trace
  ( SpanState (..),
    closeSpan,
    currentSpanId,
    getSpanStack,
    newSpanState,
    openSpan,
    setSpanStack,
  )
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
    roMode :: StepMode,
    roProjectHash :: Maybe Text
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

-- | Type env for @schema(T)@ at runtime (aliases from the loaded module).
loadTypeEnv :: ModuleBody -> TypeEnv
loadTypeEnv body = case inferModuleEnv body of
  Right env -> env
  Left _ -> preludeTypeEnv

-- | Ambient run context (spec §01 §4) injected at runtime only.
mkCtxValue :: Text -> Text -> Value
mkCtxValue runId started =
  VRecord
    [ ( Ident "run",
        VRecord
          [ (Ident "id", VString runId),
            (Ident "started_at", VString started)
          ]
      )
    ]

withRunCtx :: Text -> Text -> Env -> Env
withRunCtx runId started env =
  extendEnv (Ident "ctx") (mkCtxValue runId started) env

sectionMap :: LoadedModule -> Map Slug Text
sectionMap loaded =
  Map.fromList
    [(secSlug s, secBody s) | s <- lmSections loaded]

runLoadedModule :: RunOptions -> LoadedModule -> IO RunOutcome
runLoadedModule opts loaded = do
  ws <- newWorkspace opts.roWorkspace
  runId <- maybe newRunId pure opts.roRunId
  let hash = maybe (projectHashOf loaded) id opts.roProjectHash
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
  spans <- newSpanState
  let (baseEnv0, funs) = loadRunEnv (lmBody loaded)
      typeEnv = loadTypeEnv (lmBody loaded)
      baseEnv = withRunCtx runId started baseEnv0
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
            rcTypeEnv = typeEnv,
            rcSchemaDocs = lmSchemaDocs loaded,
            rcStore = store,
            rcProjectHash = hash,
            rcSeq = seqRef,
            rcSpans = spans
          }
      modName = "module:" <> qnameToText (fmName (lmFrontmatter loaded))
  hPutStrLn stderr ("pml run: run_id=" <> T.unpack runId)
  moduleSid <- openSpan store spans modName SkModule (object [])
  case startMain funs baseEnv opts.roInputs of
    Left err -> do
      let m0 = initialMachine hash (CurReturn VUnit)
          m =
            m0
              { mStatus = MsFailed,
                mError = Just err
              }
      stack <- getSpanStack spans
      counter <- readIORef spans.ssCounter
      persistTransition store seqRef hash Nothing Nothing MsFailed (Just m) stack counter
      closeSpan store spans moduleSid SsError (object []) Nothing
      pure (OutcomeFailed err store 0)
    Right current -> do
      let m0 = initialMachine hash current
      m1 <- runUntilPause ctx opts.roMode m0
      seqNo <- readIORef seqRef
      closeModuleSpan store spans moduleSid m1.mStatus
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

closeModuleSpan :: RunStore -> SpanState -> Text -> MachineStatus -> IO ()
closeModuleSpan store spans sid status = case status of
  MsCompleted -> closeSpan store spans sid SsOk (object []) Nothing
  MsFailed -> closeSpan store spans sid SsError (object []) Nothing
  -- Leave module span open across pause / step; resume continues under it.
  _ -> pure ()

mkCtx ::
  LlmProvider ->
  FilePath ->
  LoadedModule ->
  RunStore ->
  Text ->
  Text ->
  Text ->
  IORef Int ->
  SpanState ->
  IO RunCtx
mkCtx provider wsRoot loaded store hash runId started seqRef spans = do
  ws <- newWorkspace wsRoot
  let (baseEnv0, funs) = loadRunEnv (lmBody loaded)
      typeEnv = loadTypeEnv (lmBody loaded)
      baseEnv = withRunCtx runId started baseEnv0
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
        rcTypeEnv = typeEnv,
        rcSchemaDocs = lmSchemaDocs loaded,
        rcStore = store,
        rcProjectHash = hash,
        rcSeq = seqRef,
        rcSpans = spans
      }

loadExisting ::
  FilePath ->
  Text ->
  LlmProvider ->
  IO (Either RuntimeError (RunCtx, Machine, RunStore, IORef Int))
loadExisting workspace runId provider = do
  ws <- newWorkspace workspace
  let root = workspaceRoot ws
  store <- openRunStore root runId
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
                spans <- newSpanState
                writeIORef spans.ssCounter snap.rsSpanCounter
                setSpanStack spans snap.rsSpanStack
                ctx <- mkCtx provider root loaded store hash meta.rmRunId meta.rmStartedAt seqRef spans
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
          closeModuleIfTerminal ctx store m1.mStatus
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
          closeModuleIfTerminal ctx store m1.mStatus
          finalizeOutcome store seqNo m1
  where
    store0 = RunStore (workspace </> ".pml" </> "runs" </> T.unpack runId) runId

approveRun :: FilePath -> Text -> Bool -> LlmProvider -> IO RunOutcome
approveRun workspace runId yes provider = do
  ws <- newWorkspace workspace
  let root = workspaceRoot ws
  loaded <- loadExisting root runId provider
  case loaded of
    Left e -> pure (OutcomeFailed e (RunStore (root </> ".pml" </> "runs" </> T.unpack runId) runId) 0)
    Right (ctx, machine0, store, seqRef) ->
      case approveMachine yes machine0 of
        Left e -> pure (OutcomeFailed e store 0)
        Right machine1 -> do
          mSid <- currentSpanId ctx.rcSpans
          case mSid of
            Just sid ->
              closeSpan
                store
                ctx.rcSpans
                sid
                (if yes then SsOk else SsCancelled)
                (object ["approved" .= yes])
                Nothing
            Nothing -> pure ()
          stack <- getSpanStack ctx.rcSpans
          counter <- readIORef ctx.rcSpans.ssCounter
          persistTransition
            store
            seqRef
            ctx.rcProjectHash
            (Just HostHumanConfirm)
            (Just (VBool yes))
            machine1.mStatus
            (Just machine1)
            stack
            counter
          m2 <- runUntilPause ctx StepRun machine1
          seqNo <- readIORef seqRef
          closeModuleIfTerminal ctx store m2.mStatus
          finalizeOutcome store seqNo m2

-- | Close the outermost open span (module) on terminal status. Stack is
-- innermost-first, so the module id is last.
closeModuleIfTerminal :: RunCtx -> RunStore -> MachineStatus -> IO ()
closeModuleIfTerminal ctx store status = case status of
  MsCompleted -> closeOutermost SsOk
  MsFailed -> closeOutermost SsError
  _ -> pure ()
  where
    closeOutermost st = do
      stack <- getSpanStack ctx.rcSpans
      case reverse stack of
        (sid : _) -> closeSpan store ctx.rcSpans sid st (object []) Nothing
        [] -> pure ()

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
