-- | Exception containment (H-2): a throw from a provider, a host op or an
-- observer must end the run as a failure with a persisted snapshot, never as
-- a process crash.
module Hwfl.Runtime.ExceptionSpec (spec) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Exception (trySync)
import Hwfl.Llm.Mock (mockProviderWith)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types (ProviderError (..))
import Hwfl.Obs.Observer (ObsEvent (..), Observer, SpanOpenInfo (..), noopObserver)
import Hwfl.Obs.Span (SpanRecord (..), SpanStatus (..))
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Error (RuntimeError (..), isCatchable)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (Machine (..), MachineStatus (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import Hwfl.Runtime.Snapshot (RunSnapshot (..))
import Hwfl.Runtime.Store (RunStore, readRunSnapshot, readSpanRecords)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | Provider that throws instead of returning 'Left' — what a real adapter
-- does when a socket dies mid-request.
throwingProvider :: LlmProvider
throwingProvider =
  LlmProvider
    { llmChat = \_ -> throwIO (ErrorCall "connection reset"),
      llmProviderName = "throwing"
    }

-- | Observer that throws once, on the named span. Span state has already been
-- mutated at that point, so it also exercises span unwinding.
throwOnSpanOpen :: Text -> IO Observer
throwOnSpanOpen name = do
  fired <- newIORef False
  pure $ \case
    ObsSpanOpen info | info.soName == name -> do
      already <- readIORef fired
      if already
        then pure ()
        else do
          writeIORef fired True
          throwIO (ErrorCall "observer exploded")
    _ -> pure ()

runOpts :: FilePath -> FilePath -> Text -> RunOptions
runOpts dir path runId =
  RunOptions
    { roWorkspace = dir,
      roProvider = mockProviderWith (\_ -> Left (OtherProviderError "unused")),
      roInputs = [],
      roRunId = Just runId,
      roEntry = path,
      roMode = StepRun,
      roProjectHash = Nothing,
      roExec = Nothing,
      roObserver = noopObserver,
      roCost = False,
      roModelCatalog = "model-catalog.json",
      roSkillCatalog = fst emptySkillRuntime,
      roSkillModules = snd emptySkillRuntime,
      roEntryModules = mempty
    }

runSource :: Text -> FilePath -> RunOptions -> IO RunOutcome
runSource src path opts =
  case loadModuleText path src of
    Left diags -> fail ("parse failed: " <> show diags)
    Right loaded -> case checkLoadedModule loaded of
      Left err -> fail ("check failed: " <> show err)
      Right _ -> runLoadedModule opts loaded

chatSrc :: Text
chatSrc =
  T.unlines
    [ "---",
      "name: workflows/chat",
      "inputs: {}",
      "outputs:",
      "  msg: String",
      "effects: [Net]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { msg: String } =",
      "  { msg = llm.chat(system = \"s\", prompt = \"hi\", model = \"gpt-5\") }",
      "```"
    ]

chatCatchSrc :: Text
chatCatchSrc =
  T.unlines
    [ "---",
      "name: workflows/chat-catch",
      "inputs: {}",
      "outputs:",
      "  msg: String",
      "effects: [Net]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { msg: String } =",
      "  { msg =",
      "    try llm.chat(system = \"s\", prompt = \"hi\", model = \"gpt-5\")",
      "    catch (err) => $\"fallback: {err}\"",
      "  }",
      "```"
    ]

agentSrc :: Text
agentSrc =
  T.unlines
    [ "---",
      "name: workflows/agent",
      "inputs: {}",
      "outputs:",
      "  msg: String",
      "effects: [Net]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { msg: String } =",
      "  { msg = llm.agent(system = \"s\", prompt = \"hi\", tools = [], model = \"gpt-5\").text }",
      "```"
    ]

readSrc :: Text
readSrc =
  T.unlines
    [ "---",
      "name: workflows/read",
      "inputs: {}",
      "outputs:",
      "  text: String",
      "effects: [Read]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { text: String } =",
      "  { text = fs.read(\"note.txt\").text }",
      "```"
    ]

failureOf :: RunOutcome -> IO (RuntimeError, RunStore)
failureOf = \case
  OutcomeFailed err store _ -> pure (err, store)
  OutcomeCompleted v _ _ -> fail ("expected failure, completed with " <> show v)
  OutcomePaused _ msg _ _ -> fail ("expected failure, paused: " <> T.unpack msg)

spec :: Spec
spec = describe "exception containment (H-2)" $ do
  it "turns a throwing provider into a provider failure" $
    withSystemTempDirectory "hwfl-exc-chat" $ \dir -> do
      let path = dir </> "chat.md"
          opts = (runOpts dir path "test-exc-chat") {roProvider = throwingProvider}
      (err, _) <- failureOf =<< runSource chatSrc path opts
      case err of
        ProviderErr msg -> msg `shouldSatisfy` ("connection reset" `T.isInfixOf`)
        other -> expectationFailure ("expected ProviderErr, got " <> show other)

  it "lets author code catch a throwing provider" $
    withSystemTempDirectory "hwfl-exc-catch" $ \dir -> do
      let path = dir </> "chat-catch.md"
          opts = (runOpts dir path "test-exc-catch") {roProvider = throwingProvider}
      outcome <- runSource chatCatchSrc path opts
      case outcome of
        OutcomeCompleted (VRecord fields) _ _ ->
          case lookup (Ident "msg") fields of
            Just (VString msg) -> msg `shouldSatisfy` ("fallback:" `T.isPrefixOf`)
            _ -> expectationFailure "expected msg field"
        other -> expectationFailure ("expected completion, got " <> show other)

  it "turns a throwing provider into a provider failure inside the agent loop" $
    withSystemTempDirectory "hwfl-exc-agent" $ \dir -> do
      let path = dir </> "agent.md"
          opts = (runOpts dir path "test-exc-agent") {roProvider = throwingProvider}
      (err, _) <- failureOf =<< runSource agentSrc path opts
      case err of
        ProviderErr msg -> msg `shouldSatisfy` ("connection reset" `T.isInfixOf`)
        other -> expectationFailure ("expected ProviderErr, got " <> show other)

  it "reports a crash inside a step as a non-catchable internal error" $
    withSystemTempDirectory "hwfl-exc-step" $ \dir -> do
      observer <- throwOnSpanOpen "fs.read"
      let path = dir </> "read.md"
          opts = (runOpts dir path "test-exc-step") {roObserver = observer}
      (err, _) <- failureOf =<< runSource readSrc path opts
      case err of
        InternalErr msg -> do
          msg `shouldSatisfy` ("observer exploded" `T.isInfixOf`)
          isCatchable err `shouldBe` False
        other -> expectationFailure ("expected InternalErr, got " <> show other)

  it "persists the failed machine so a resume cannot replay the step" $
    withSystemTempDirectory "hwfl-exc-persist" $ \dir -> do
      observer <- throwOnSpanOpen "fs.read"
      let path = dir </> "read.md"
          opts = (runOpts dir path "test-exc-persist") {roObserver = observer}
      (_, store) <- failureOf =<< runSource readSrc path opts
      mSnap <- readRunSnapshot store
      case mSnap of
        Nothing -> expectationFailure "expected a snapshot for the crashed run"
        Just snap -> do
          snap.rsStatus `shouldBe` MsFailed
          fmap (.mStatus) snap.rsMachine `shouldBe` Just MsFailed

  it "closes the span the crashed step opened" $
    withSystemTempDirectory "hwfl-exc-spans" $ \dir -> do
      observer <- throwOnSpanOpen "fs.read"
      let path = dir </> "read.md"
          opts = (runOpts dir path "test-exc-spans") {roObserver = observer}
      (_, store) <- failureOf =<< runSource readSrc path opts
      records <- readSpanRecords store
      let opened = [r.srId | r <- records, r.srName == Just "fs.read"]
          closed = [r.srId | r <- records, r.srOp == "close", r.srStatus == Just SsError]
      opened `shouldSatisfy` (not . null)
      all (`elem` closed) opened `shouldBe` True

  it "does not contain exit or async exceptions" $ do
    r <- try (trySync (exitWith (ExitFailure 7)))
    case r of
      Left code -> code `shouldBe` ExitFailure 7
      Right _ -> expectationFailure "trySync swallowed ExitCode"
