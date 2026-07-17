module Hwfl.Runtime.RunSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (MachineStatus (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import Hwfl.Runtime.Snapshot (RunSnapshot (..), readRunSnapshot)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

summariseSrc :: Text
summariseSrc =
  T.unlines
    [ "---",
      "name: workflows/summarise",
      "inputs:",
      "  path: FileRef",
      "outputs:",
      "  summary: String",
      "effects: [Read, Net]",
      "---",
      "",
      "## system",
      "",
      "You are a concise summariser. Return one paragraph, no preamble.",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(inputs): { summary: String } =",
      "  let contents = fs.read(inputs.path)",
      "  let summary = llm.chat(",
      "    system = @system,",
      "    prompt = $\"Summarise the following:\\n\\n{contents.text}\",",
      "    model = \"gpt-5\"",
      "  )",
      "  { summary }",
      "```"
    ]

e03Src :: Text
e03Src =
  T.unlines
    [ "---",
      "name: workflows/e03",
      "inputs: {}",
      "outputs:",
      "  reply: String",
      "effects: [Net]",
      "---",
      "",
      "## system",
      "",
      "You are helpful.",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { reply: String } =",
      "  let reply = llm.chat(",
      "    system = @system,",
      "    prompt = \"Say hi\",",
      "    model = \"gpt-5\"",
      "  )",
      "  { reply }",
      "```"
    ]

spec :: Spec
spec = describe "runtime run (M4/M5)" $ do
  it "E03 section prompt + mock llm.chat" $
    withSystemTempDirectory "hwfl-run" $ \dir -> do
      case loadModuleText "e03.md" e03Src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          let opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [],
                    roRunId = Just "test-e03",
                    roEntry = dir </> "e03.md",
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roDebug = False
                  }
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted val _ seqNo -> do
              val `shouldBe` VRecord [(Ident "reply", VString "SUMMARY: Say hi")]
              seqNo `shouldSatisfy` (>= 1)
            other -> expectationFailure (show other)

  it "E04 summarise with mock LLM + sandbox read" $
    withSystemTempDirectory "hwfl-run" $ \dir -> do
      let doc = dir </> "doc.txt"
      writeFile doc "Alpha beta gamma."
      -- Persist module path for meta entry (hash uses lmPath from loadModuleText).
      writeFile (dir </> "summarise.md") (T.unpack summariseSrc)
      case loadModuleText (dir </> "summarise.md") summariseSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          let opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [(Ident "path", VString "doc.txt")],
                    roRunId = Just "test-e04",
                    roEntry = dir </> "summarise.md",
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roDebug = False
                  }
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted val store seqNo -> do
              seqNo `shouldSatisfy` (>= 2)
              case val of
                VRecord [(Ident "summary", VString s)] ->
                  T.isPrefixOf "SUMMARY: Summarise the following:" s
                    `shouldBe` True
                other -> expectationFailure ("unexpected result: " <> show other)
              mSnap <- readRunSnapshot store
              case mSnap of
                Nothing -> expectationFailure "missing snapshot"
                Just snap -> do
                  snap.rsFormat `shouldBe` 1
                  snap.rsStatus `shouldBe` MsCompleted
                  snap.rsRunId `shouldBe` "test-e04"
                  snap.rsMachine `shouldSatisfy` (/= Nothing)
            other -> expectationFailure (show other)

  it "sandbox escape via fs.read is rejected" $
    withSystemTempDirectory "hwfl-run" $ \dir -> do
      let src =
            T.unlines
              [ "---",
                "name: workflows/escape",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  text: String",
                "effects: [Read]",
                "---",
                "",
                "## body",
                "",
                "```hwfl",
                "fun main(inputs): { text: String } =",
                "  let r = fs.read(inputs.path)",
                "  { text = r.text }",
                "```"
              ]
      case loadModuleText "escape.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          let opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [(Ident "path", VString "../outside.txt")],
                    roRunId = Just "test-escape",
                    roEntry = "escape.md",
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roDebug = False
                  }
          outcome <- runLoadedModule opts loaded
          outcome `shouldSatisfy` isFailed

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isFailed :: RunOutcome -> Bool
isFailed = \case
  OutcomeFailed {} -> True
  _ -> False
