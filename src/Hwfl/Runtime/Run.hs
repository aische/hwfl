-- | Execute / step / resume / approve a loaded module under a host environment.
module Hwfl.Runtime.Run
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
    emptySkillRuntime,
  )
where

import Data.Aeson (object, (.=))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..), Section (..))
import Hwfl.Ast.Name (Ident (..), QName (..), Slug, qnameToText)
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Env (TypeEnv)
import Hwfl.Check.Infer (inferModuleEnv)
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Eval.Error (EvalError (..))
import Hwfl.Eval.Prelude (preludeEnv)
import Hwfl.Eval.Pure (bindParams)
import Hwfl.Eval.Value
import Hwfl.Llm.Pricing (ModelPricing, loadModelPricing)
import Hwfl.Llm.Provider (LlmProvider)
import Hwfl.Obs.Span (SpanKind (..), SpanStatus (..))
import Hwfl.Obs.Trace
  ( SpanState (..),
    closeSpan,
    currentSpanId,
    getSpanStack,
    newSpanStateDebug,
    openSpan,
    setSpanStack,
  )
import Hwfl.Project (ExecPolicy (..), LoadedProject (..), ProjectConfig (..), loadProject, loadProjectConfig)
import Hwfl.Parse.Load (loadModule)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Eval
  ( RunCtx (..),
    StepMode (..),
    approveMachine,
    runUntilPause,
  )
import Hwfl.Runtime.Host (HostEnv (..), hostOpsEnv)
import Hwfl.Runtime.Machine
import Hwfl.Runtime.Snapshot
import Hwfl.Runtime.Workspace (newWorkspace, workspaceRoot)
import Data.Set qualified as Set
import Hwfl.SkillCatalog
  ( SkillCatalog,
    buildSkillCatalog,
    defaultSkillPolicy,
    emptySkillCatalog,
    isSkillQName,
    skillMetaForModule,
  )
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import Data.Maybe (fromMaybe)

data RunOptions = RunOptions
  { roWorkspace :: FilePath,
    roProvider :: LlmProvider,
    roInputs :: [(Ident, Value)],
    roRunId :: Maybe Text,
    roEntry :: FilePath,
    roMode :: StepMode,
    roProjectHash :: Maybe Text,
    -- | Exec policy from @project.json@; 'Nothing' disables @exec.run@.
    roExec :: Maybe ExecPolicy,
    -- | Live span open/close lines on stderr (CLI @--debug@).
    roDebug :: Bool,
    -- | Model catalog for LLM cost attribution.
    roModelCatalog :: FilePath,
    -- | Skill catalog from @hwfl check@ (empty when running a lone module).
    roSkillCatalog :: SkillCatalog,
    -- | Callable skill modules for mid-loop tool advertising.
    roSkillModules :: Map QName LoadedModule
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
withRunCtx runId started = extendEnv (Ident "ctx") (mkCtxValue runId started)

sectionMap :: LoadedModule -> Map Slug Text
sectionMap loaded =
  Map.fromList
    [(secSlug s, secBody s) | s <- lmSections loaded]

runLoadedModule :: RunOptions -> LoadedModule -> IO RunOutcome
runLoadedModule opts loaded = do
  ws <- newWorkspace opts.roWorkspace
  runId <- maybe newRunId pure opts.roRunId
  let hash = fromMaybe (projectHashOf loaded) opts.roProjectHash
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
  let debugLog =
        if opts.roDebug
          then Just (hPutStrLn stderr . T.unpack)
          else Nothing
  spans <- newSpanStateDebug debugLog
  pricing <- loadModelPricing opts.roModelCatalog
  let (baseEnv0, funs) = loadRunEnv (lmBody loaded)
      typeEnv = loadTypeEnv (lmBody loaded)
      baseEnv = withRunCtx runId started baseEnv0
      skillFuns = buildSkillFunTables opts.roSkillModules
      host =
        HostEnv
          { heWorkspace = ws,
            heProvider = opts.roProvider,
            heExec = opts.roExec,
            heSkillCatalog = opts.roSkillCatalog,
            hePricing = pricing,
            heLog = hPutStrLn stderr . T.unpack
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
            rcSpans = spans,
            rcSkillFuns = skillFuns,
            rcSkillModules = opts.roSkillModules
          }
      modName = "module:" <> qnameToText (fmName (lmFrontmatter loaded))
  hPutStrLn stderr ("hwfl run: run_id=" <> T.unpack runId)
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
    pure (OutcomeCompleted (fromMaybe VUnit m.mLastResult) store seqNo)
  MsFailed ->
    pure
      ( OutcomeFailed
          (fromMaybe (EvalErr (Trap "failed")) m.mError)
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
  ModelPricing ->
  FilePath ->
  LoadedModule ->
  RunStore ->
  Text ->
  Text ->
  Text ->
  IORef Int ->
  SpanState ->
  SkillCatalog ->
  Map QName LoadedModule ->
  IO RunCtx
mkCtx provider pricing wsRoot loaded store hash runId started seqRef spans catalog skillMods = do
  ws <- newWorkspace wsRoot
  execPol <- loadExecPolicy wsRoot
  let (baseEnv0, funs) = loadRunEnv (lmBody loaded)
      typeEnv = loadTypeEnv (lmBody loaded)
      baseEnv = withRunCtx runId started baseEnv0
      host =
        HostEnv
          { heWorkspace = ws,
            heProvider = provider,
            heExec = execPol,
            heSkillCatalog = catalog,
            hePricing = pricing,
            heLog = hPutStrLn stderr . T.unpack
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
        rcSpans = spans,
        rcSkillFuns = buildSkillFunTables skillMods,
        rcSkillModules = skillMods
      }

buildSkillFunTables :: Map QName LoadedModule -> Map QName (Env, FunTable)
buildSkillFunTables =
  Map.mapMaybeWithKey $ \_q m ->
    case smKind (skillMetaForModule m) of
      SkillInstruction -> Nothing
      SkillCallable -> Just (loadRunEnv (lmBody m))

-- | Load @exec@ policy from workspace @project.json@ when present.
loadExecPolicy :: FilePath -> IO (Maybe ExecPolicy)
loadExecPolicy root = do
  cfgE <- loadProjectConfig root
  pure $ case cfgE of
    Right cfg -> cfg.pcExec
    Left _ -> Nothing

-- | Empty skill catalog / modules for single-module runs and tests.
emptySkillRuntime :: (SkillCatalog, Map QName LoadedModule)
emptySkillRuntime = (emptySkillCatalog defaultSkillPolicy, Map.empty)

-- | Best-effort skill runtime from a workspace project (for resume).
loadSkillRuntime :: FilePath -> IO (SkillCatalog, Map QName LoadedModule)
loadSkillRuntime root = do
  lpE <- loadProject root
  pure $ case lpE of
    Left _ -> (emptySkillCatalog defaultSkillPolicy, Map.empty)
    Right lp ->
      let skills =
            Map.filterWithKey (\q _ -> isSkillQName q) lp.lpModules
          checked = Set.fromList (Map.keys skills)
          catalog = buildSkillCatalog lp.lpConfig.pcSkills skills checked
          callables =
            Map.filter (\m -> smKind (skillMetaForModule m) == SkillCallable) skills
       in (catalog, callables)

loadExisting ::
  FilePath ->
  Text ->
  LlmProvider ->
  FilePath ->
  IO (Either RuntimeError (RunCtx, Machine, RunStore, IORef Int))
loadExisting workspace runId provider catalogPath = do
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
                spans <- newSpanStateDebug Nothing
                writeIORef spans.ssCounter snap.rsSpanCounter
                setSpanStack spans snap.rsSpanStack
                (catalog, skillMods) <- loadSkillRuntime root
                pricing <- loadModelPricing catalogPath
                ctx <-
                  mkCtx
                    provider
                    pricing
                    root
                    loaded
                    store
                    hash
                    meta.rmRunId
                    meta.rmStartedAt
                    seqRef
                    spans
                    catalog
                    skillMods
                pure (Right (ctx, machine, store, seqRef))
    _ -> pure (Left (ConfigErr "missing meta.json or snapshot.json"))

stepRun :: FilePath -> Text -> LlmProvider -> FilePath -> IO RunOutcome
stepRun workspace runId provider catalogPath = do
  loaded <- loadExisting workspace runId provider catalogPath
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
    store0 = RunStore (workspace </> ".hwfl" </> "runs" </> T.unpack runId) runId
    failed store e = pure (OutcomeFailed e store 0)

resumeRun :: FilePath -> Text -> LlmProvider -> FilePath -> IO RunOutcome
resumeRun workspace runId provider catalogPath = do
  loaded <- loadExisting workspace runId provider catalogPath
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
    store0 = RunStore (workspace </> ".hwfl" </> "runs" </> T.unpack runId) runId

approveRun :: FilePath -> Text -> Bool -> LlmProvider -> FilePath -> IO RunOutcome
approveRun workspace runId yes provider catalogPath = do
  ws <- newWorkspace workspace
  let root = workspaceRoot ws
  loaded <- loadExisting root runId provider catalogPath
  case loaded of
    Left e -> pure (OutcomeFailed e (RunStore (root </> ".hwfl" </> "runs" </> T.unpack runId) runId) 0)
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
