-- | Library driver façade: check / run / step / resume / approve / show /
-- run-store queries / live observer.
--
-- The CLI is one frontend over this API. A future control-plane app should
-- call the same operations rather than reimplementing project load + check +
-- execute orchestration. Live span / pause events go through 'Observer'
-- (CLI @--debug@ installs 'stderrDebugObserver'; WS/SSE maps onto the same).
module Hwfl.Driver
  ( -- * Check
    DriverError (..),
    DriverCheckOk (..),
    driverCheck,
    renderDriverError,

    -- * Run
    DriverRunRequest (..),
    defaultDriverRunRequest,
    driverRun,

    -- * Continue an existing run
    driverStep,
    driverResume,
    driverApprove,
    driverChoose,
    driverReply,
    driverExtendAgent,

    -- * Inspect
    driverShow,

    -- * Run store (lab / control-plane queries)
    driverListRuns,
    driverReadMeta,
    driverReadSpans,
    driverReadSnapshot,
    driverOpenRun,

    -- * Live observer
    Observer,
    ObsEvent (..),
    SpanOpenInfo (..),
    SpanCloseInfo (..),
    PauseInfo (..),
    FinishedInfo (..),
    noopObserver,
    stderrDebugObserver,
    mappendObserver,

    -- * Re-exports for frontends
    RunOutcome (..),
    ShowMode (..),
    ShowOptions (..),
    RunMeta (..),
    RunSnapshot (..),
    SpanFilter (..),
    emptySpanFilter,
    RunRef (..),
    runRef,
    RunStore,
    storeRunId,
    SpanRecord (..),
    RunStoreBackend (..),
    fsRunStoreBackend,
    defaultRunStoreBackend,
  )
where

import Data.Text (Text)
import Hwfl.Ast.Name (Ident)
import Hwfl.Check.Error (CheckError, renderLocatedCheckError)
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Check.Project
  ( CheckProjectResult (..),
    ProjectCheckError (..),
    checkProject,
    renderProjectCheckError,
  )
import Hwfl.Eval.Value (Value)
import Hwfl.Llm.Provider (LlmProvider)
import Hwfl.Obs.Observer
  ( FinishedInfo (..),
    ObsEvent (..),
    Observer,
    PauseInfo (..),
    SpanCloseInfo (..),
    SpanOpenInfo (..),
    mappendObserver,
    noopObserver,
    stderrDebugObserver,
  )
import Hwfl.Obs.Show (ShowMode (..), ShowOptions (..), showRun)
import Hwfl.Obs.Span (SpanRecord (..))
import Hwfl.Parse.Load (loadModule)
import Hwfl.Project (isProjectDir)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOutcome (..),
    RunTargetError (..),
    RunTargetRequest (..),
    approveRun,
    chooseRun,
    defaultRunTargetRequest,
    extendAgentRun,
    resumeRun,
    replyRun,
    runTarget,
    stepRun,
  )
import Hwfl.Runtime.Snapshot (RunMeta (..), RunSnapshot (..))
import Hwfl.Runtime.Store
  ( RunRef (..),
    RunStore,
    RunStoreBackend (..),
    SpanFilter (..),
    defaultRunStoreBackend,
    emptySpanFilter,
    fsRunStoreBackend,
    listRuns,
    openRun,
    readMeta,
    readSnapshot,
    readSpans,
    runRef,
    storeRunId,
  )
import Hwfl.Source (Diagnostic, renderDiagnostics)

-- | Failures that occur before a 'RunOutcome' exists (load / parse / check).
data DriverError
  = DeProject ProjectCheckError
  | DeParse FilePath [Diagnostic]
  | DeModule FilePath CheckError
  deriving stock (Eq, Show)

data DriverCheckOk
  = -- | Single-module check succeeded.
    CheckOkModule
  | -- | Project graph check succeeded (includes skill catalog).
    CheckOkProject CheckProjectResult
  deriving stock (Eq, Show)

renderDriverError :: DriverError -> Text
renderDriverError = \case
  DeProject err -> renderProjectCheckError err
  DeParse _ diags -> renderDiagnostics diags
  DeModule path err -> renderLocatedCheckError path err

-- | Static check of a project directory or a single @.md@ module.
driverCheck :: FilePath -> IO (Either DriverError DriverCheckOk)
driverCheck path = do
  isProj <- isProjectDir path
  if isProj
    then do
      result <- checkProject path
      pure $ case result of
        Left err -> Left (DeProject err)
        Right ok -> Right (CheckOkProject ok)
    else do
      result <- loadModule path
      pure $ case result of
        Left diags -> Left (DeParse path diags)
        Right loaded -> case checkLoadedModule loaded of
          Left err -> Left (DeModule path err)
          Right _ -> Right CheckOkModule

-- | Request to start a new run (project or single module).
data DriverRunRequest = DriverRunRequest
  { drrTarget :: FilePath,
    drrWorkspace :: FilePath,
    drrInputs :: [(Ident, Value)],
    drrProvider :: LlmProvider,
    -- | Skip static check before execute (CLI @--no-check@).
    drrSkipCheck :: Bool,
    drrModelCatalog :: FilePath,
    drrMode :: StepMode,
    -- | Live span / pause observer (default: noop).
    drrObserver :: Observer,
    drrCost :: Bool,
    drrRunId :: Maybe Text
  }

defaultDriverRunRequest :: FilePath -> FilePath -> LlmProvider -> DriverRunRequest
defaultDriverRunRequest target workspace provider =
  DriverRunRequest
    { drrTarget = target,
      drrWorkspace = workspace,
      drrInputs = [],
      drrProvider = provider,
      drrSkipCheck = False,
      drrModelCatalog = "model-catalog.json",
      drrMode = StepRun,
      drrObserver = noopObserver,
      drrCost = False,
      drrRunId = Nothing
    }

toRunTargetRequest :: DriverRunRequest -> RunTargetRequest
toRunTargetRequest req =
  (defaultRunTargetRequest req.drrTarget req.drrWorkspace req.drrProvider)
    { rtrInputs = req.drrInputs,
      rtrSkipCheck = req.drrSkipCheck,
      rtrModelCatalog = req.drrModelCatalog,
      rtrMode = req.drrMode,
      rtrObserver = req.drrObserver,
      rtrCost = req.drrCost,
      rtrRunId = req.drrRunId
    }

mapTargetError :: RunTargetError -> DriverError
mapTargetError = \case
  RtProject err -> DeProject err
  RtParse path diags -> DeParse path diags
  RtModule path err -> DeModule path err

-- | Check (unless skipped) then execute @main@ for a project or module path.
driverRun :: DriverRunRequest -> IO (Either DriverError RunOutcome)
driverRun req = do
  result <- runTarget (toRunTargetRequest req)
  pure $ case result of
    Left err -> Left (mapTargetError err)
    Right outcome -> Right outcome

driverStep :: FilePath -> Text -> LlmProvider -> FilePath -> Observer -> IO RunOutcome
driverStep = stepRun

driverResume :: FilePath -> Text -> LlmProvider -> FilePath -> Observer -> IO RunOutcome
driverResume = resumeRun

driverApprove :: FilePath -> Text -> Bool -> LlmProvider -> FilePath -> Observer -> IO RunOutcome
driverApprove = approveRun

driverChoose :: FilePath -> Text -> Text -> LlmProvider -> FilePath -> Observer -> IO RunOutcome
driverChoose = chooseRun

driverReply :: FilePath -> Text -> Text -> LlmProvider -> FilePath -> Observer -> IO RunOutcome
driverReply = replyRun

driverExtendAgent :: FilePath -> Text -> Int -> LlmProvider -> FilePath -> Observer -> IO RunOutcome
driverExtendAgent = extendAgentRun

driverShow :: ShowOptions -> IO (Either Text Text)
driverShow = showRun

-- | List runs under a workspace (@.hwfl/runs@ for the FS backend).
driverListRuns :: FilePath -> IO [RunMeta]
driverListRuns = listRuns

driverOpenRun :: RunRef -> IO (Maybe RunStore)
driverOpenRun = openRun

driverReadMeta :: RunRef -> IO (Maybe RunMeta)
driverReadMeta ref = do
  mStore <- openRun ref
  case mStore of
    Nothing -> pure Nothing
    Just store -> readMeta store

driverReadSpans :: RunRef -> SpanFilter -> IO [SpanRecord]
driverReadSpans ref filt = do
  mStore <- openRun ref
  case mStore of
    Nothing -> pure []
    Just store -> readSpans store filt

driverReadSnapshot :: RunRef -> IO (Maybe RunSnapshot)
driverReadSnapshot ref = do
  mStore <- openRun ref
  case mStore of
    Nothing -> pure Nothing
    Just store -> readSnapshot store
