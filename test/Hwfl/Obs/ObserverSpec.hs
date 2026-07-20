module Hwfl.Obs.ObserverSpec (spec) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Driver
  ( DriverRunRequest (..),
    FinishedInfo (..),
    ObsEvent (..),
    PauseInfo (..),
    RunOutcome (..),
    SpanOpenInfo (..),
    defaultDriverRunRequest,
    driverRun,
  )
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Span (SpanKind (..))
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    runLoadedModule,
    emptySkillRuntime,
  )
import Hwfl.Runtime.Store (readRunMeta, storeRunId)
import Hwfl.Runtime.Snapshot (RunMeta (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

collectingObserver :: IORef [ObsEvent] -> ObsEvent -> IO ()
collectingObserver ref ev =
  atomicModifyIORef' ref (\xs -> (xs ++ [ev], ()))

spanOpenNames :: [ObsEvent] -> [T.Text]
spanOpenNames =
  concatMap $ \case
    ObsSpanOpen i -> [i.soName]
    _ -> []

pauseEvents :: [ObsEvent] -> [PauseInfo]
pauseEvents =
  concatMap $ \case
    ObsPaused p -> [p]
    _ -> []

finishedStatuses :: [ObsEvent] -> [T.Text]
finishedStatuses =
  concatMap $ \case
    ObsFinished i -> [i.fiStatus]
    _ -> []

confirmSrc :: T.Text
confirmSrc =
  T.unlines
    [ "---",
      "name: workflows/obs-pause",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "effects: [Human]",
      "---",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool } =",
      "  let ok = confirm { title = \"gate\", detail = \"please\" }",
      "  { ok }",
      "```"
    ]

pureSrc :: T.Text
pureSrc =
  T.unlines
    [ "---",
      "name: workflows/obs-pure",
      "inputs: {}",
      "outputs:",
      "  n: Int",
      "effects: []",
      "---",
      "",
      "```hwfl",
      "fun main(_): { n: Int } =",
      "  let clustered = obs.span(\"cluster\")(fun () => 7)",
      "  { n = clustered }",
      "```"
    ]

spec :: Spec
spec = describe "live observer hook" $ do
  it "emits span open/close and finished for a pure run" $
    withSystemTempDirectory "hwfl-obs" $ \dir -> do
      evsRef <- newIORef ([] :: [ObsEvent])
      case loadModuleText (dir </> "pure.md") pureSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          let (catalog, skillMods) = emptySkillRuntime
              opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [],
                    roRunId = Just "obs-pure",
                    roEntry = dir </> "pure.md",
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = collectingObserver evsRef,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = catalog,
                    roSkillModules = skillMods, roEntryModules = mempty
                  }
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted (VRecord fields) store _ -> do
              lookup (Ident "n") fields `shouldBe` Just (VInt 7)
              storeRunId store `shouldBe` "obs-pure"
              evs <- readIORef evsRef
              spanOpenNames evs
                `shouldContain` ["module:workflows/obs-pure", "cluster"]
              finishedStatuses evs `shouldBe` ["completed"]
              mMeta <- readRunMeta store
              fmap (.rmStatus) mMeta `shouldBe` Just "completed"
            other -> expectationFailure ("expected completed, got: " <> show other)

  it "emits ObsPaused with confirm fields on human gate" $
    withSystemTempDirectory "hwfl-obs-pause" $ \dir -> do
      evsRef <- newIORef ([] :: [ObsEvent])
      case loadModuleText (dir </> "pause.md") confirmSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          let (catalog, skillMods) = emptySkillRuntime
              opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [],
                    roRunId = Just "obs-pause",
                    roEntry = dir </> "pause.md",
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = collectingObserver evsRef,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = catalog,
                    roSkillModules = skillMods, roEntryModules = mempty
                  }
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomePaused _ msg store _ -> do
              msg `shouldBe` "awaiting confirm: gate"
              evs <- readIORef evsRef
              case pauseEvents evs of
                [p] -> do
                  p.piRunId `shouldBe` "obs-pause"
                  p.piStatus `shouldBe` "awaiting_confirm"
                  p.piConfirmTitle `shouldBe` Just "gate"
                  p.piConfirmDetail `shouldBe` Just "please"
                other -> expectationFailure ("expected one pause, got: " <> show other)
              mMeta <- readRunMeta store
              fmap (.rmStatus) mMeta `shouldBe` Just "awaiting_confirm"
              finishedStatuses evs `shouldBe` []
            other -> expectationFailure ("expected paused, got: " <> show other)

  it "driverRun accepts a collecting observer" $
    withSystemTempDirectory "hwfl-obs-driver" $ \dir -> do
      evsRef <- newIORef ([] :: [ObsEvent])
      let path = dir </> "x.md"
      writeFile
        path
        ( T.unpack $
            T.unlines
              [ "---",
                "name: workflows/x",
                "inputs: {}",
                "outputs: {}",
                "effects: []",
                "---",
                "",
                "```hwfl",
                "fun main(_): {} = {}",
                "```"
              ]
        )
      let req =
            (defaultDriverRunRequest path dir mockProvider)
              { drrRunId = Just "drv-obs",
                drrObserver = collectingObserver evsRef,
                drrModelCatalog = "model-catalog.json"
              }
      result <- driverRun req
      case result of
        Right (OutcomeCompleted _ _ _) -> do
          evs <- readIORef evsRef
          any
            ( \case
                ObsSpanOpen i -> i.soKind == SkModule
                _ -> False
            )
            evs
            `shouldBe` True
          finishedStatuses evs `shouldBe` ["completed"]
        other -> expectationFailure ("expected completed, got: " <> show other)
