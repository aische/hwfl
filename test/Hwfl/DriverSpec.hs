module Hwfl.DriverSpec (spec) where

import Data.Text qualified as T
import Hwfl.Driver
  ( DriverCheckOk (..),
    DriverError (..),
    DriverRunRequest (..),
    RunOutcome (..),
    defaultDriverRunRequest,
    driverCheck,
    driverRun,
    driverShow,
  )
import Hwfl.Check.Project (ProjectCheckError (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Show (ShowMode (..), ShowOptions (..))
import Hwfl.Runtime.Store (storeRunId)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

fixtureRoot :: FilePath -> FilePath
fixtureRoot name = "test/fixtures" </> name

spec :: Spec
spec = describe "library driver façade" $ do
  describe "driverCheck" $ do
    it "accepts a multi-module project" $ do
      result <- driverCheck (fixtureRoot "check-project")
      case result of
        Right (CheckOkProject _) -> pure ()
        other -> expectationFailure ("expected CheckOkProject, got: " <> show other)

    it "rejects a cyclic project" $ do
      result <- driverCheck (fixtureRoot "check-project-cycle")
      case result of
        Left (DeProject (PceImportCycle _)) -> pure ()
        other -> expectationFailure ("expected import cycle, got: " <> show other)

    it "accepts a well-typed single module" $
      withSystemTempDirectory "hwfl-driver-check" $ \dir -> do
        let path = dir </> "ok.md"
        writeFile
          path
          ( T.unpack $
              T.unlines
                [ "---",
                  "name: workflows/ok",
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
        result <- driverCheck path
        result `shouldBe` Right CheckOkModule

  describe "driverRun" $ do
    it "runs a pure module via the façade" $
      withSystemTempDirectory "hwfl-driver-run" $ \dir -> do
        let path = dir </> "pure.md"
        writeFile
          path
          ( T.unpack $
              T.unlines
                [ "---",
                  "name: workflows/pure",
                  "inputs: {}",
                  "outputs:",
                  "  n: Int",
                  "effects: []",
                  "---",
                  "",
                  "```hwfl",
                  "fun main(_): { n: Int } = { n = 42 }",
                  "```"
                ]
          )
        let req =
              (defaultDriverRunRequest path dir mockProvider)
                { drrRunId = Just "driver-pure",
                  drrModelCatalog = "model-catalog.json"
                }
        result <- driverRun req
        case result of
          Right (OutcomeCompleted _ store _) ->
            storeRunId store `shouldBe` "driver-pure"
          other -> expectationFailure ("expected completed, got: " <> show other)

    it "surfaces check failure without starting a run" $
      withSystemTempDirectory "hwfl-driver-bad" $ \dir -> do
        let path = dir </> "bad.md"
        writeFile
          path
          ( T.unpack $
              T.unlines
                [ "---",
                  "name: workflows/bad",
                  "inputs: {}",
                  "outputs: {}",
                  "effects: []",
                  "---",
                  "",
                  "```hwfl",
                  "fun main(_): {} = missing_var",
                  "```"
                ]
          )
        let req = defaultDriverRunRequest path dir mockProvider
        result <- driverRun req
        case result of
          Left (DeModule _ _) -> pure ()
          other -> expectationFailure ("expected DeModule, got: " <> show other)

  describe "driverShow" $ do
    it "shows a completed run created by driverRun" $
      withSystemTempDirectory "hwfl-driver-show" $ \dir -> do
        let path = dir </> "show.md"
        writeFile
          path
          ( T.unpack $
              T.unlines
                [ "---",
                  "name: workflows/show",
                  "inputs: {}",
                  "outputs:",
                  "  n: Int",
                  "effects: []",
                  "---",
                  "",
                  "```hwfl",
                  "fun main(_): { n: Int } = { n = 7 }",
                  "```"
                ]
          )
        let req =
              (defaultDriverRunRequest path dir mockProvider)
                { drrRunId = Just "driver-show"
                }
        _ <- driverRun req
        shown <-
          driverShow
            ShowOptions
              { soWorkspace = dir,
                soRunId = "driver-show",
                soMode = ShowSummary,
                soFilter = Nothing
              }
        case shown of
          Left err -> expectationFailure (T.unpack err)
          Right txt -> do
            T.isInfixOf "driver-show" txt `shouldBe` True
            T.isInfixOf "completed" txt `shouldBe` True
