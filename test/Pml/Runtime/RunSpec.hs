module Pml.Runtime.RunSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..))
import Pml.Check.Module (checkLoadedModule)
import Pml.Eval.Value (Value (..))
import Pml.Llm.Mock (mockProvider)
import Pml.Parse.Load (loadModuleText)
import Pml.Runtime.Run
  ( RunOptions (..),
    RunResult (..),
    runLoadedModule,
  )
import Pml.Runtime.Snapshot (BoundarySnapshot (..), RunStatus (..), readBoundarySnapshot)
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
      "```pml",
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
      "```pml",
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
spec = describe "runtime run (M4)" $ do
  it "E03 section prompt + mock llm.chat" $
    withSystemTempDirectory "pml-run" $ \dir -> do
      case loadModuleText "e03.md" e03Src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          let opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [],
                    roRunId = Just "test-e03"
                  }
          runRes <- runLoadedModule opts loaded
          case runRes of
            Left err -> expectationFailure (show err)
            Right rr -> do
              rr.rrValue `shouldBe` VRecord [(Ident "reply", VString "SUMMARY: Say hi")]
              rr.rrSeq `shouldBe` 1
              mSnap <- readBoundarySnapshot rr.rrStore
              case mSnap of
                Nothing -> expectationFailure "missing snapshot"
                Just snap -> do
                  snap.bsStatus `shouldBe` StatusCompleted
                  snap.bsSeq `shouldBe` 1
                  snap.bsLastHost `shouldBe` Nothing -- final completion snapshot clears last_host
                  -- Host transition wrote seq=1; completion rewrite may omit last_host.
                  -- Check transitions existed via store + seq from host.
                  pure ()

  it "E04 summarise with mock LLM + sandbox read" $
    withSystemTempDirectory "pml-run" $ \dir -> do
      let doc = dir </> "doc.txt"
      writeFile doc "Alpha beta gamma."
      case loadModuleText "summarise.md" summariseSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          let opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [(Ident "path", VString "doc.txt")],
                    roRunId = Just "test-e04"
                  }
          runRes <- runLoadedModule opts loaded
          case runRes of
            Left err -> expectationFailure (show err)
            Right rr -> do
              -- fs.read + llm.chat => seq 2; completion write keeps seq
              rr.rrSeq `shouldSatisfy` (>= 2)
              case rr.rrValue of
                VRecord [(Ident "summary", VString s)] ->
                  T.isPrefixOf "SUMMARY: Summarise the following:" s
                    `shouldBe` True
                other -> expectationFailure ("unexpected result: " <> show other)
              mSnap <- readBoundarySnapshot rr.rrStore
              case mSnap of
                Nothing -> expectationFailure "missing snapshot"
                Just snap -> do
                  snap.bsFormat `shouldBe` 1
                  snap.bsStatus `shouldBe` StatusCompleted
                  snap.bsRunId `shouldBe` "test-e04"

  it "sandbox escape via fs.read is rejected" $
    withSystemTempDirectory "pml-run" $ \dir -> do
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
                "```pml",
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
                    roRunId = Just "test-escape"
                  }
          runRes <- runLoadedModule opts loaded
          runRes `shouldSatisfy` isLeft

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isLeft :: Either a b -> Bool
isLeft = not . isRight
