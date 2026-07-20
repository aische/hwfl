module Hwfl.Runtime.TrySpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProviderWith)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Llm.Types (ProviderError (..))
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
    emptySkillRuntime,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

failingProvider :: RunOptions -> RunOptions
failingProvider opts =
  opts
    { roProvider =
        mockProviderWith
          ( \_ ->
              Left (OtherProviderError ("forced failure" :: Text) :: ProviderError)
          )
    }

e10Src :: Text
e10Src =
  T.unlines
    [ "---",
      "name: workflows/e10",
      "inputs: {}",
      "outputs:",
      "  msg: String",
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
      "fun main(_): { msg: String } =",
      "  { msg =",
      "    try",
      "      llm.chat(",
      "        system = @system,",
      "        prompt = \"hi\",",
      "        model = \"gpt-5\"",
      "      )",
      "    catch (err) =>",
      "      $\"fallback: {err}\"",
      "  }",
      "```"
    ]

fsCatchSrc :: Text
fsCatchSrc =
  T.unlines
    [ "---",
      "name: workflows/fs-catch",
      "inputs: {}",
      "outputs:",
      "  msg: String",
      "effects: [Read]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { msg: String } =",
      "  let outcome =",
      "    try fs.read(\"missing.txt\")",
      "    catch (err) => { text = $\"caught: {err}\" }",
      "  { msg = outcome.text }",
      "```"
    ]

trapSrc :: Text
trapSrc =
  T.unlines
    [ "---",
      "name: workflows/trap",
      "inputs: {}",
      "outputs:",
      "  msg: String",
      "effects: []",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { msg: String } =",
      "  try",
      "    unknown_var",
      "  catch (err) =>",
      "    \"never\"",
      "```"
    ]

runModule ::
  Text ->
  FilePath ->
  RunOptions ->
  IO (Either Text Value)
runModule src path opts =
  case loadModuleText path src of
    Left diags -> pure (Left (T.pack (show diags)))
    Right loaded -> do
      case checkLoadedModule loaded of
        Left err -> pure (Left (T.pack (show err)))
        Right _ -> do
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted v _ _ -> pure (Right v)
            OutcomeFailed err _ _ -> pure (Left (T.pack (show err)))
            OutcomePaused _ _ _ _ -> pure (Left "paused unexpectedly")

spec :: Spec
spec = describe "try/catch runtime (E10)" $ do
  it "catches provider failure and returns fallback string" $
    withSystemTempDirectory "hwfl-try" $ \dir -> do
      let path = dir </> "e10.md"
          opts =
            (failingProvider $
               RunOptions
                 { roWorkspace = dir,
                   roProvider = mockProviderWith (\_ -> Left (OtherProviderError "forced failure")),
                   roInputs = [],
                   roRunId = Just "test-e10",
                   roEntry = path,
                   roMode = StepRun,
                   roProjectHash = Nothing,
                   roExec = Nothing,
                   roObserver = noopObserver,
                   roCost = False,
                   roModelCatalog = "model-catalog.json",
                   roSkillCatalog = fst emptySkillRuntime,
                   roSkillModules = snd emptySkillRuntime, roEntryModules = mempty
                 })
      result <- runModule e10Src path opts
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right (VRecord fields) ->
          case lookup (Ident "msg") fields of
            Just (VString msg) ->
              msg `shouldSatisfy` ("fallback:" `T.isPrefixOf`)
            _ -> expectationFailure "expected msg field"
        Right other -> expectationFailure ("unexpected value: " <> show other)

  it "catches fs.read host error" $
    withSystemTempDirectory "hwfl-try-fs" $ \dir -> do
      let path = dir </> "fs-catch.md"
          opts =
            RunOptions
              { roWorkspace = dir,
                roProvider = mockProviderWith (\_ -> Left (OtherProviderError "unused")),
                roInputs = [],
                roRunId = Just "test-fs-catch",
                roEntry = path,
                roMode = StepRun,
                roProjectHash = Nothing,
                roExec = Nothing,
                roObserver = noopObserver,
                roCost = False,
                roModelCatalog = "model-catalog.json",
                roSkillCatalog = fst emptySkillRuntime,
                roSkillModules = snd emptySkillRuntime, roEntryModules = mempty
              }
      result <- runModule fsCatchSrc path opts
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right (VRecord fields) ->
          case lookup (Ident "msg") fields of
            Just (VString msg) ->
              msg `shouldSatisfy` ("caught:" `T.isPrefixOf`)
            _ -> expectationFailure "expected msg field"
        Right other -> expectationFailure ("unexpected value: " <> show other)

  it "catches host error with projection in try body" $
    withSystemTempDirectory "hwfl-try-proj" $ \dir -> do
      let src =
            T.unlines
              [ "---",
                "name: workflows/proj",
                "inputs: {}",
                "outputs:",
                "  msg: String",
                "effects: [Read]",
                "---",
                "",
                "## body",
                "",
                "```hwfl",
                "fun main(_): { msg: String } =",
                "  { msg =",
                "    try fs.read(\"missing.txt\").text",
                "    catch (err) => $\"caught: {err}\"",
                "  }",
                "```"
              ]
          path = dir </> "proj.md"
          opts =
            RunOptions
              { roWorkspace = dir,
                roProvider = mockProviderWith (\_ -> Left (OtherProviderError "unused")),
                roInputs = [],
                roRunId = Just "test-proj",
                roEntry = path,
                roMode = StepRun,
                roProjectHash = Nothing,
                roExec = Nothing,
                roObserver = noopObserver,
                roCost = False,
                roModelCatalog = "model-catalog.json",
                roSkillCatalog = fst emptySkillRuntime,
                roSkillModules = snd emptySkillRuntime, roEntryModules = mempty
              }
      result <- runModule src path opts
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right (VRecord fields) ->
          case lookup (Ident "msg") fields of
            Just (VString msg) ->
              msg `shouldSatisfy` ("caught:" `T.isPrefixOf`)
            _ -> expectationFailure "expected msg field"
        Right other -> expectationFailure ("unexpected value: " <> show other)

  it "does not catch pure trap errors" $
    withSystemTempDirectory "hwfl-try-trap" $ \dir -> do
      let path = dir </> "trap.md"
          opts =
            RunOptions
              { roWorkspace = dir,
                roProvider = mockProviderWith (\_ -> Left (OtherProviderError "unused")),
                roInputs = [],
                roRunId = Just "test-trap",
                roEntry = path,
                roMode = StepRun,
                roProjectHash = Nothing,
                roExec = Nothing,
                roObserver = noopObserver,
                roCost = False,
                roModelCatalog = "model-catalog.json",
                roSkillCatalog = fst emptySkillRuntime,
                roSkillModules = snd emptySkillRuntime, roEntryModules = mempty
              }
      outcome <- runModule trapSrc path opts
      outcome `shouldSatisfy` isLeft

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
