module Hwfl.Obs.StreamSpec (spec) where

import Data.Aeson (eitherDecode, object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Llm.Types (StreamDelta (..), ToolCall (..))
import Hwfl.Obs.Span (SpanKind (..), SpanStatus (..))
import Hwfl.Obs.Stream (StreamSink (..), newStreamSink)
import Hwfl.Obs.Trace
  ( closeSpan,
    newSpanState,
    openSpan,
  )
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import Hwfl.Runtime.Snapshot (RunStore (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

e03Src :: Text
e03Src =
  T.unlines
    [ "---",
      "name: workflows/e03-stream",
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
      "    prompt = \"Say hello world from stream test\",",
      "    model = \"gpt-5\"",
      "  )",
      "  { reply }",
      "```"
    ]

spec :: Spec
spec = describe "streaming LLM spans" $ do
  it "coalesces text deltas into fewer events" $
    withSystemTempDirectory "hwfl-stream" $ \dir -> do
      let store = RunStore {storeRoot = dir, storeRunId = "s1"}
      st <- newSpanState
      sid <- openSpan store st "llm.chat" SkHost (object [])
      sink <- newStreamSink store st
      -- 8-char provider chunks; coalescer flushes at 64 chars.
      mapM_ sink.ssOnChunk [DeltaText (T.replicate 8 "a") | _ <- [1 .. 12 :: Int]]
      sink.ssFlush
      closeSpan store st sid SsOk (object []) Nothing
      events <- readEvents dir
      let deltas = [e | e <- events, eMessage e == "llm.delta"]
      length deltas `shouldSatisfy` (>= 1)
      length deltas `shouldSatisfy` (<= 3)
      mconcat [t | e <- deltas, Just t <- [fieldText e "text"]]
        `shouldBe` T.replicate 96 "a"
      map eSpanId deltas `shouldBe` replicate (length deltas) (Just sid)

  it "flushes text before a tool_call delta" $
    withSystemTempDirectory "hwfl-stream-tc" $ \dir -> do
      let store = RunStore {storeRoot = dir, storeRunId = "s2"}
      st <- newSpanState
      _ <- openSpan store st "agent_round:0" SkAgentRound (object [])
      sink <- newStreamSink store st
      sink.ssOnChunk (DeltaText "hi")
      sink.ssOnChunk
        ( DeltaToolCall
            ToolCall
              { tcId = "c1",
                tcName = "fs_read",
                tcArguments = object []
              }
        )
      sink.ssFlush
      events <- readEvents dir
      let deltas = [e | e <- events, eMessage e == "llm.delta"]
      map (`fieldTextStr` "kind") deltas `shouldBe` ["text", "tool_call"]

  it "llm.chat run writes llm.delta events on the open host span" $
    withSystemTempDirectory "hwfl-stream-run" $ \dir -> do
      case loadModuleText "e03.md" e03Src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          let opts =
                RunOptions
                  { roWorkspace = dir,
                    roProvider = mockProvider,
                    roInputs = [],
                    roRunId = Just "stream-run",
                    roEntry = dir </> "e03.md",
                    roMode = StepRun,
                    roProjectHash = Nothing,
                    roExec = Nothing,
                    roDebug = False,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                  }
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted (VRecord fs) store _ -> do
              lookup (Ident "reply") fs
                `shouldBe` Just (VString "SUMMARY: Say hello world from stream test")
              events <- readEvents store.storeRoot
              let deltas = [e | e <- events, eMessage e == "llm.delta"]
              null deltas `shouldBe` False
              all (\e -> fieldText e "kind" == Just "text") deltas `shouldBe` True
              let joined = mconcat [t | e <- deltas, Just t <- [fieldText e "text"]]
              joined `shouldBe` "SUMMARY: Say hello world from stream test"
            other -> expectationFailure (show other)

data EventLine = EventLine
  { eMessage :: Text,
    eSpanId :: Maybe Text,
    eFields :: Aeson.Value
  }
  deriving stock (Show)

readEvents :: FilePath -> IO [EventLine]
readEvents root = do
  let path = root </> "events.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      bs <- LBS8.readFile path
      let lines_ = filter (not . LBS8.null) (LBS8.lines bs)
      pure (mapMaybe decodeEvent lines_)
  where
    decodeEvent bs = case eitherDecode bs of
      Left _ -> Nothing
      Right v -> parseMaybe parseEvent v
    parseEvent = withObject "event" $ \o -> do
      msg <- o .: "message"
      sid <- o .:? "span_id"
      fields <- o .:? "fields"
      pure
        EventLine
          { eMessage = msg,
            eSpanId = sid,
            eFields = fromMaybe Aeson.Null fields
          }

fieldText :: EventLine -> Text -> Maybe Text
fieldText e k = case e.eFields of
  Aeson.Object o -> case KM.lookup (Key.fromText k) o of
    Just (Aeson.String t) -> Just t
    _ -> Nothing
  _ -> Nothing

fieldTextStr :: EventLine -> Text -> Text
fieldTextStr e k = fromMaybe "" (fieldText e k)
