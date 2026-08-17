module Hwfl.Cli.ArgsSpec (spec) where

import Hwfl.Cli.Args
  ( RunFlags (..),
    flagProviderSet,
    parseApprove,
    parseCheckFlags,
    parseChoose,
    parseExtend,
    parseInitFlags,
    parseReply,
    parseRunFlags,
    parseShow,
    parseWsRun,
    wantsJson,
  )
import Hwfl.Obs.Show (ShowMode (..))
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

  describe "parseInitFlags" $ do
    it "defaults to ." $
      parseInitFlags [] `shouldBe` Right "."
    it "accepts a directory" $
      parseInitFlags ["my-app"] `shouldBe` Right "my-app"
    it "accepts dash-prefixed path after --" $
      parseInitFlags ["--", "-app"] `shouldBe` Right "-app"
    it "rejects unknown flags" $
      parseInitFlags ["--json"] `shouldBe` Left "unknown flag: --json"
    it "rejects a second path" $
      parseInitFlags ["a", "b"] `shouldBe` Left "unexpected argument: b"

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
    it "parses --example and --input together" $
      case parseRunFlags ["mod.md", "--example", "note", "--input", "path=other.md"] of
        Right f -> do
          f.rfExample `shouldBe` Just "note"
          f.rfInputs `shouldBe` ["path=other.md"]
        Left err -> expectationFailure err
    it "treats --example as value-taking for wantsJson" $
      wantsJson ["--example", "--json", "mod.md"] `shouldBe` False

  describe "parseWsRun" $ do
    it "accepts dash-prefixed workspace after --" $
      parseWsRun ["--", "-ws", "run1"]
        `shouldBe` Right ("-ws", Just "run1", "simple", "model-catalog.json", False)
    it "omits run-id when only workspace is given" $
      parseWsRun ["ws"]
        `shouldBe` Right ("ws", Nothing, "simple", "model-catalog.json", False)
    it "accepts explicit latest token" $
      parseWsRun ["ws", "latest"]
        `shouldBe` Right ("ws", Just "latest", "simple", "model-catalog.json", False)
    it "rejects a missing workspace" $
      parseWsRun ["--dump"]
        `shouldBe` Left "usage: hwfl step|resume <workspace> [run-id] [options]"

  describe "parseApprove" $ do
    it "allows omitted run-id with --yes" $
      parseApprove ["ws", "--yes"]
        `shouldBe` Right ("ws", Nothing, True, "simple", "model-catalog.json", False)
    it "still requires --yes or --no" $
      parseApprove ["ws"] `shouldBe` Left "hwfl approve needs --yes or --no"
    it "keeps an explicit run-id" $
      parseApprove ["ws", "run-1", "--no"]
        `shouldBe` Right ("ws", Just "run-1", False, "simple", "model-catalog.json", False)

  describe "parseChoose" $ do
    it "allows omitted run-id with --select" $
      parseChoose ["ws", "--select", "staging"]
        `shouldBe` Right ("ws", Nothing, "staging", "simple", "model-catalog.json", False)

  describe "parseReply" $ do
    it "allows omitted run-id with --text" $
      parseReply ["ws", "--text", "hi"]
        `shouldBe` Right ("ws", Nothing, "hi", "simple", "model-catalog.json", False)

  describe "parseExtend" $ do
    it "allows omitted run-id with --rounds" $
      parseExtend ["ws", "--rounds", "4"]
        `shouldBe` Right ("ws", Nothing, 4, "simple", "model-catalog.json", False)

  describe "parseShow" $ do
    it "allows omitted run-id" $
      parseShow ["ws"] `shouldBe` Right ("ws", Nothing, ShowSummary, Nothing)
    it "accepts latest plus --tree" $
      parseShow ["ws", "latest", "--tree"]
        `shouldBe` Right ("ws", Just "latest", ShowTree, Nothing)

  describe "runtimeExitCode" $ do
    it "maps StaleProjectErr to 4" $
      runtimeExitCode StaleProjectErr `shouldBe` 4
    it "maps other config errors to 1" $
      runtimeExitCode (ConfigErr "stale project: hash mismatch") `shouldBe` 1
