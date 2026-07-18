module Hwfl.Obs.SpanSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Infer (infer)
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Eval.Value (HostOpId (..), Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Obs.Redact (hostOpenAttrs, redactJson, redactMarker, redactValue)
import Hwfl.Obs.Span (SpanKind (..), SpanStatus (..))
import Hwfl.Obs.Show (ShowMode (..), ShowOptions (..), showRun)
import Hwfl.Obs.Trace
  ( SpanNode (..),
    buildSpanForest,
    closeSpan,
    newSpanState,
    openSpan,
    readSpanRecords,
    runCostPrefix,
  )
import Hwfl.Parse.Expr (parseExprText)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import Hwfl.Runtime.Snapshot (valueToJson)
import Hwfl.Runtime.Store (openRunDir, storeRunId)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

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
      "    prompt = \"Say hi with secret sk-SUPERSECRETKEYVALUE0123456789ABCDEF\",",
      "    model = \"gpt-5\"",
      "  )",
      "  { reply }",
      "```"
    ]

-- | E16 — polymorphic @obs.span@ returns the body value (not Unit).
e16Src :: Text
e16Src =
  T.unlines
    [ "---",
      "name: workflows/e16-span",
      "inputs: {}",
      "outputs:",
      "  n: Int",
      "  label: String",
      "effects: []",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { n: Int, label: String } =",
      "  let clustered = obs.span(\"cluster\")(fun () =>",
      "    { n = 3, label = \"ok\" }",
      "  )",
      "  clustered",
      "```"
    ]

inferE :: Text -> Either String TypeExpr
inferE src = case parseExprText "e" src of
  Left err -> Left (errorBundlePretty err)
  Right e -> either (Left . show) Right (infer preludeTypeEnv e)

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

  describe "running cost prefix" $ do
    it "formats $0.00 │ when no LLM spend yet" $ do
      st <- newSpanState
      prefix <- runCostPrefix st
      prefix `shouldBe` "$0.00 │ "

    it "accumulates sub-cent cost_micros across closes for the prefix" $
      withSystemTempDirectory "hwfl-cost-prefix" $ \dir -> do
        store <- openRunDir dir "cost-prefix"
        st <- newSpanState
        let cheapAttrs =
              object
                [ "token_in" .= (5000 :: Int),
                  "token_out" .= (1000 :: Int),
                  "cost_micros" .= (980 :: Int),
                  "cost_usd" .= (0.00098 :: Double)
                ]
        -- 12 × 980 micros = 11760 → displays as $0.01 (cent-per-span rounding stayed $0.00)
        mapM_
          ( \n -> do
              sid <- openSpan store st ("llm." <> T.pack (show n)) SkHost (object [])
              closeSpan store st sid SsOk cheapAttrs Nothing
          )
          [1 .. 12 :: Int]
        prefix <- runCostPrefix st
        prefix `shouldBe` "$0.01 │ "

  describe "polymorphic obs.span (E16)" $ do
    it "infers obs.span(name)(fun () => e) as the type of e" $ do
      inferE "obs.span(\"cluster\")(fun () => 42)"
        `shouldBe` Right (TName (TypeName "Int"))
      inferE "obs.span(\"cluster\", fun () => \"hi\")"
        `shouldBe` Right (TName (TypeName "String"))

    it "checks and runs a non-Unit value through a region span" $
      withSystemTempDirectory "hwfl-e16" $ \dir -> do
        let path = dir </> "e16.md"
        writeFile path (T.unpack e16Src)
        case loadModuleText path e16Src of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            outcome <-
              runLoadedModule
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [],
                    roRunId = Just "e16",
                    roEntry = path,
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                  }
                loaded
            case outcome of
              OutcomeCompleted (VRecord fs) store _ -> do
                lookup (Ident "n") fs `shouldBe` Just (VInt 3)
                lookup (Ident "label") fs `shouldBe` Just (VString "ok")
                records <- readSpanRecords store
                let forest = buildSpanForest records
                case forest of
                  [root] -> do
                    T.isPrefixOf "module:" root.snName `shouldBe` True
                    map (.snName) root.snChildren `shouldBe` ["cluster"]
                  other -> expectationFailure ("expected one root, got " <> show (length other))
              other -> expectationFailure (show other)

  describe "spans.jsonl + show" $ do
    it "emits nested module/host spans and tree show" $
      withSystemTempDirectory "hwfl-obs" $ \dir -> do
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
                      roMode = StepRun,
                      roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted _ store _ -> do
                let spansPath =
                      dir </> ".hwfl" </> "runs" </> T.unpack (storeRunId store) </> "spans.jsonl"
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
