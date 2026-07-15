module Pml.Obs.SpanSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Value (HostOpId (..), Value (..))
import Pml.Llm.Mock (mockProvider)
import Pml.Obs.Redact (hostOpenAttrs, redactJson, redactMarker, redactValue)
import Pml.Obs.Show (ShowMode (..), ShowOptions (..), showRun)
import Pml.Obs.Trace (SpanNode (..), buildSpanForest, readSpanRecords)
import Pml.Parse.Load (loadModuleText)
import Pml.Runtime.Eval (StepMode (..))
import Pml.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import Pml.Runtime.Snapshot (RunStore (..), valueToJson)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

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
      "    prompt = \"Say hi with secret sk-SUPERSECRETKEYVALUE0123456789ABCDEF\",",
      "    model = \"gpt-5\"",
      "  )",
      "  { reply }",
      "```"
    ]

spec :: Spec
spec = describe "observability (M6)" $ do
  describe "redaction" $ do
    it "redacts VSecret in values and snapshots" $ do
      let secret = VSecret (VString "hunter2")
      redactValue secret `shouldBe` VSecret (VString redactMarker)
      case valueToJson secret of
        Aeson.Object km -> do
          KM.lookup "tag" km `shouldBe` Just (Aeson.String "secret")
          KM.lookup "v" km `shouldBe` Just (Aeson.String redactMarker)
        other -> expectationFailure ("expected object, got " <> show other)
      redactJson (object ["api_key" .= Aeson.String "tok", "n" .= Aeson.Number 1])
        `shouldBe` object ["api_key" .= Aeson.String redactMarker, "n" .= Aeson.Number 1]

    it "host open attrs never include llm prompt text" $ do
      let args =
            [ (Just (Ident "system"), VString "sys"),
              (Just (Ident "prompt"), VString "TOP SECRET PROMPT BODY"),
              (Just (Ident "model"), VString "gpt-5")
            ]
          attrs = hostOpenAttrs HostLlmChat args
          encoded = LBS8.unpack (encode attrs)
      encoded `shouldNotContain` "TOP SECRET"
      case attrs of
        Aeson.Object km -> do
          KM.lookup "model" km `shouldBe` Just (Aeson.String "gpt-5")
          KM.lookup "prompt_len" km
            `shouldBe` Just (Aeson.Number (fromIntegral (T.length "TOP SECRET PROMPT BODY")))
        _ -> expectationFailure "expected attrs object"

  describe "spans.jsonl + show" $ do
    it "emits nested module/host spans and tree show" $
      withSystemTempDirectory "pml-obs" $ \dir -> do
        case loadModuleText "e03.md" e03Src of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "test-obs",
                      roEntry = dir </> "e03.md",
                      roMode = StepRun
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted _ store _ -> do
                let spansPath = store.storeRoot </> "spans.jsonl"
                exists <- doesFileExist spansPath
                exists `shouldBe` True
                records <- readSpanRecords store
                length records `shouldSatisfy` (>= 4) -- module open/close + llm open/close
                let forest = buildSpanForest records
                case forest of
                  [root] -> do
                    T.isPrefixOf "module:" root.snName `shouldBe` True
                    map (.snName) root.snChildren `shouldBe` ["llm.chat"]
                  other -> expectationFailure ("expected one root, got " <> show (length other))
                raw <- readFile spansPath
                raw `shouldNotContain` "TOP SECRET"
                raw `shouldNotContain` "SUPERSECRETKEYVALUE"
                shown <-
                  showRun
                    ShowOptions
                      { soWorkspace = dir,
                        soRunId = "test-obs",
                        soMode = ShowTree,
                        soFilter = Nothing
                      }
                case shown of
                  Left err -> expectationFailure (T.unpack err)
                  Right txt -> do
                    T.isInfixOf "module:workflows/e03" txt `shouldBe` True
                    T.isInfixOf "llm.chat" txt `shouldBe` True
              other -> expectationFailure (show other)
