module Hwfl.Cli.InitSpec (spec) where

import Data.Text qualified as T
import Hwfl.Cli.Init (InitError (..), InitResult (..), scaffoldProject)
import Hwfl.Driver
  ( DriverRunRequest (..),
    RunOutcome (..),
    defaultDriverRunRequest,
    driverApprove,
    driverCheck,
    driverResolveRunId,
    driverRun,
    noopObserver,
    storeRunId,
  )
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Runtime.Eval (StepMode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "scaffoldProject" $ do
    it "writes project.json and workflows/main.md" $
      withSystemTempDirectory "hwfl-init" $ \dir -> do
        let root = dir </> "hello-app"
        result <- scaffoldProject root
        case result of
          Left err -> expectationFailure (show err)
          Right ok -> do
            ok.irProjectName `shouldBe` "hello-app"
            length ok.irCreated `shouldBe` 2

    it "refuses to overwrite an existing project.json" $
      withSystemTempDirectory "hwfl-init" $ \dir -> do
        Right _ <- scaffoldProject dir
        again <- scaffoldProject dir
        again `shouldBe` Left (InitAlreadyExists (dir </> "project.json"))

    it "scaffolded project type-checks" $
      withSystemTempDirectory "hwfl-init" $ \dir -> do
        Right _ <- scaffoldProject dir
        checked <- driverCheck dir
        checked `shouldSatisfy` either (const False) (const True)

    it "scaffolded project pauses on confirm under mock LLM" $
      withSystemTempDirectory "hwfl-init" $ \dir -> do
        Right _ <- scaffoldProject dir
        let req =
              (defaultDriverRunRequest dir dir mockProvider)
                { drrSkipCheck = False,
                  drrMode = StepRun,
                  drrObserver = noopObserver
                }
        outcome <- driverRun req
        case outcome of
          Left err -> expectationFailure (show err)
          Right (OutcomePaused _ msg store _) -> do
            T.unpack msg `shouldContain` "Accept this greeting?"
            resolved <- driverResolveRunId dir Nothing
            resolved `shouldBe` Right (storeRunId store)
            approved <-
              driverApprove
                dir
                (storeRunId store)
                True
                mockProvider
                "model-catalog.json"
                noopObserver
            case approved of
              OutcomeCompleted {} -> pure ()
              _ -> expectationFailure "expected completed after approve"
          Right _ -> expectationFailure "expected pause on confirm"
