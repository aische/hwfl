-- | Library driver façade: check / run / step / resume / approve / show.
--
-- The CLI is one frontend over this API. A future control-plane app should
-- call the same operations rather than reimplementing project load + check +
-- execute orchestration. Run-store backend abstraction is a separate P1.
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

    -- * Inspect
    driverShow,

    -- * Re-exports for frontends
    RunOutcome (..),
    ShowMode (..),
    ShowOptions (..),
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfl.Ast.Module (LoadedModule)
import Hwfl.Ast.Name (Ident, QName, qnameToText)
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Error (CheckError, renderCheckError)
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Check.Project
  ( CheckProjectResult (..),
    ProjectCheckError (..),
    checkProject,
    checkProjectLoaded,
    renderProjectCheckError,
  )
import Hwfl.Eval.Value (Value)
import Hwfl.Llm.Provider (LlmProvider)
import Hwfl.Obs.Show (ShowMode (..), ShowOptions (..), showRun)
import Hwfl.Parse.Load (loadModule)
import Hwfl.Project
  ( ExecPolicy,
    LoadedProject (..),
    ProjectConfig (..),
    isProjectDir,
    loadProject,
    modulePathForQname,
    projectHashForModules,
  )
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    approveRun,
    emptySkillRuntime,
    resumeRun,
    runLoadedModule,
    stepRun,
  )
import Hwfl.SkillCatalog (SkillCatalog, isSkillQName, skillMetaForModule)
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
  DeModule _ err -> renderCheckError err

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
    drrDebug :: Bool,
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
      drrDebug = False,
      drrCost = False,
      drrRunId = Nothing
    }

-- | Check (unless skipped) then execute @main@ for a project or module path.
driverRun :: DriverRunRequest -> IO (Either DriverError RunOutcome)
driverRun req = do
  isProj <- isProjectDir req.drrTarget
  if isProj
    then driverRunProject req
    else driverRunModule req

driverRunProject :: DriverRunRequest -> IO (Either DriverError RunOutcome)
driverRunProject req = do
  lpE <- loadProject req.drrTarget
  case lpE of
    Left err -> pure (Left (DeProject (PceLoad err)))
    Right lp -> do
      catalogE <- resolveProjectCatalog req.drrSkipCheck lp
      case catalogE of
        Left e -> pure (Left e)
        Right catalog -> do
          let entry = lp.lpConfig.pcEntrypoint
              entryPath = modulePathForQname req.drrTarget entry
              skillMods = callableSkillModules lp.lpModules
          case Map.lookup entry lp.lpModules of
            Nothing ->
              pure (Left (DeProject (PceEntryNotFound (qnameToText entry))))
            Just loaded -> do
              let opts =
                    mkRunOptions
                      req
                      entryPath
                      (Just (projectHashForModules lp.lpModules))
                      lp.lpConfig.pcExec
                      catalog
                      skillMods
              Right <$> runLoadedModule opts loaded

resolveProjectCatalog ::
  Bool ->
  LoadedProject ->
  IO (Either DriverError SkillCatalog)
resolveProjectCatalog skipCheck lp =
  if skipCheck
    then
      let (c, _) = emptySkillRuntime
       in pure (Right c)
    else pure $ case checkProjectLoaded lp of
      Left err -> Left (DeProject err)
      Right cpr -> Right cpr.cprSkillCatalog

callableSkillModules :: Map QName LoadedModule -> Map QName LoadedModule
callableSkillModules =
  Map.filterWithKey
    ( \q m ->
        isSkillQName q
          && smKind (skillMetaForModule m) == SkillCallable
    )

driverRunModule :: DriverRunRequest -> IO (Either DriverError RunOutcome)
driverRunModule req = do
  result <- loadModule req.drrTarget
  case result of
    Left diags -> pure (Left (DeParse req.drrTarget diags))
    Right loaded ->
      if not req.drrSkipCheck
        then case checkLoadedModule loaded of
          Left err -> pure (Left (DeModule req.drrTarget err))
          Right _ -> runMod loaded
        else runMod loaded
  where
    runMod loaded = do
      let (catalog, skillMods) = emptySkillRuntime
          opts =
            mkRunOptions
              req
              req.drrTarget
              Nothing
              Nothing
              catalog
              skillMods
      Right <$> runLoadedModule opts loaded

mkRunOptions ::
  DriverRunRequest ->
  FilePath ->
  Maybe Text ->
  Maybe ExecPolicy ->
  SkillCatalog ->
  Map QName LoadedModule ->
  RunOptions
mkRunOptions req entry hash execPol catalog skillMods =
  RunOptions
    { roWorkspace = req.drrWorkspace,
      roProvider = req.drrProvider,
      roInputs = req.drrInputs,
      roRunId = req.drrRunId,
      roEntry = entry,
      roMode = req.drrMode,
      roProjectHash = hash,
      roExec = execPol,
      roDebug = req.drrDebug,
      roCost = req.drrCost,
      roModelCatalog = req.drrModelCatalog,
      roSkillCatalog = catalog,
      roSkillModules = skillMods
    }

driverStep :: FilePath -> Text -> LlmProvider -> FilePath -> IO RunOutcome
driverStep = stepRun

driverResume :: FilePath -> Text -> LlmProvider -> FilePath -> IO RunOutcome
driverResume = resumeRun

driverApprove :: FilePath -> Text -> Bool -> LlmProvider -> FilePath -> IO RunOutcome
driverApprove = approveRun

driverShow :: ShowOptions -> IO (Either Text Text)
driverShow = showRun
