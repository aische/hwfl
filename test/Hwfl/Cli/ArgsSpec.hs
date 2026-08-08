module Hwfl.Cli.ArgsSpec (spec) where

import Hwfl.Cli.Args
  ( RunFlags (..),
    flagProviderSet,
    parseCheckFlags,
    parseRunFlags,
    parseWsRun,
    wantsJson,
  )
import Hwfl.Runtime.Error (RuntimeError (..), runtimeExitCode)
import Test.Hspec

spec :: Spec
spec = do
  describe "wantsJson" $ do
    it "detects bare --json" $
      wantsJson ["mod.md", "--json"] `shouldBe` True
    it "ignores --json consumed as --workspace value" $
      wantsJson ["--workspace", "--json", "mod.md"] `shouldBe` False
    it "ignores --json after --" $
      wantsJson ["--", "--json"] `shouldBe` False
    it "still sees --json before a value-taking flag value" $
      wantsJson ["--json", "--workspace", "ws"] `shouldBe` True

  describe "flagProviderSet" $ do
    it "detects bare --llm-provider" $
      flagProviderSet ["--llm-provider", "mock"] `shouldBe` True
    it "ignores --llm-provider as --workspace value" $
      flagProviderSet ["--workspace", "--llm-provider", "mod.md"] `shouldBe` False

  describe "parseCheckFlags" $ do
    it "accepts --json and a path" $
      parseCheckFlags ["proj", "--json"] `shouldBe` Right ("proj", True)
    it "accepts dash-prefixed path after --" $
      parseCheckFlags ["--", "-odd.md"] `shouldBe` Right ("-odd.md", False)
    it "rejects dash-prefixed path without --" $
      parseCheckFlags ["-odd.md"] `shouldBe` Left "unknown flag: -odd.md"

  describe "parseRunFlags" $ do
    it "accepts dash-prefixed module after --" $
      case parseRunFlags ["--", "-draft.md", "--json"] of
        Right f -> do
          f.rfModule `shouldBe` "-draft.md"
          f.rfJson `shouldBe` True
        Left err -> expectationFailure err
    it "parses flags before and after module" $
      case parseRunFlags ["--json", "mod.md", "--cost"] of
        Right f -> do
          f.rfModule `shouldBe` "mod.md"
          f.rfJson `shouldBe` True
          f.rfCost `shouldBe` True
        Left err -> expectationFailure err

  describe "parseWsRun" $ do
    it "accepts dash-prefixed workspace after --" $
      parseWsRun ["--", "-ws", "run1"]
        `shouldBe` Right ("-ws", "run1", "simple", "model-catalog.json", False)

  describe "runtimeExitCode" $ do
    it "maps StaleProjectErr to 4" $
      runtimeExitCode StaleProjectErr `shouldBe` 4
    it "maps other config errors to 1" $
      runtimeExitCode (ConfigErr "stale project: hash mismatch") `shouldBe` 1
