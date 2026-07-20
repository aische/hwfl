module Hwfl.Runtime.ConcurrentSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Driver
  ( DriverRunRequest (..),
    defaultDriverRunRequest,
    driverApprove,
    driverRun,
  )
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (AskRequest (..), ChoiceRequest (..), MachineStatus (..), PauseReason (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    approveRun,
    chooseRun,
    replyRun,
    resumeRun,
    runLoadedModule,
    emptySkillRuntime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

writeMod :: FilePath -> Text -> IO FilePath
writeMod dir src = do
  let path = dir </> "mod.md"
  writeFile path (T.unpack src)
  pure path

parSrc :: Text
parSrc =
  T.unlines
    [ "---",
      "name: workflows/par",
      "inputs: {}",
      "outputs:",
      "  texts: \"List<{ text: String }>\"",
      "effects: [Read, Parallel]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { texts: List<{ text: String }> } =",
      "  let texts =",
      "    par(max = 2) for p in [\"a.txt\", \"b.txt\", \"c.txt\"] {",
      "      fs.read(p)",
      "    }",
      "  { texts }",
      "```"
    ]

confirmSrc :: Text
confirmSrc =
  T.unlines
    [ "---",
      "name: workflows/confirm",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "effects: [Human]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool } =",
      "  let ok = confirm { title = \"Proceed?\", detail = \"demo\" }",
      "  { ok }",
      "```"
    ]

choiceSrc :: Text
choiceSrc =
  T.unlines
    [ "---",
      "name: workflows/choose",
      "inputs: {}",
      "outputs:",
      "  env: String",
      "effects: [Human]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { env: String } =",
      "  let env = choice {",
      "    title = \"Deploy?\",",
      "    detail = \"pick\",",
      "    options = [\"staging\", \"prod\", \"abort\"]",
      "  }",
      "  { env }",
      "```"
    ]

askSrc :: Text
askSrc =
  T.unlines
    [ "---",
      "name: workflows/ask",
      "inputs: {}",
      "outputs:",
      "  answer: String",
      "effects: [Human]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { answer: String } =",
      "  let answer = human.ask({ prompt = \"Your name?\" })",
      "  { answer }",
      "```"
    ]

parConfirmSrc :: Text
parConfirmSrc =
  T.unlines
    [ "---",
      "name: workflows/par-confirm",
      "inputs: {}",
      "outputs:",
      "  results: List<Bool>",
      "effects: [Human, Parallel]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { results: List<Bool> } =",
      "  let results =",
      "    par(max = 2) for name in [\"a\", \"b\"] {",
      "      confirm { title = name, detail = name }",
      "    }",
      "  { results }",
      "```"
    ]

parAskSrc :: Text
parAskSrc =
  T.unlines
    [ "---",
      "name: workflows/par-ask",
      "inputs: {}",
      "outputs:",
      "  results: List<String>",
      "effects: [Human, Parallel]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { results: List<String> } =",
      "  let results =",
      "    par(max = 2) for name in [\"first\", \"second\"] {",
      "      human.ask({ prompt = name })",
      "    }",
      "  { results }",
      "```"
    ]

spec :: Spec
spec = describe "runtime par/confirm/step (M5)" $ do
  it "E07 par map ordered results" $
    withSystemTempDirectory "hwfl-par" $ \dir -> do
      writeFile (dir </> "a.txt") "A"
      writeFile (dir </> "b.txt") "B"
      writeFile (dir </> "c.txt") "C"
      path <- writeMod dir parSrc
      case loadModuleText path parSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          -- FileRef vs String literal is a known check gap; runtime accepts path strings.
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "par1",
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
              loaded
          case outcome of
            OutcomeCompleted (VRecord [(Ident "texts", VList xs)]) _ _ ->
              xs
                `shouldBe` [ VRecord [(Ident "text", VString "A")],
                             VRecord [(Ident "text", VString "B")],
                             VRecord [(Ident "text", VString "C")]
                           ]
            other -> expectationFailure (show other)

  it "confirm + approve --yes" $
    withSystemTempDirectory "hwfl-confirm" $ \dir -> do
      path <- writeMod dir confirmSrc
      case loadModuleText path confirmSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "c1",
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
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> pure ()
            other -> expectationFailure ("expected awaiting confirm, got " <> show other)
          approved <- approveRun dir "c1" True mockProvider "model-catalog.json" noopObserver
          case approved of
            OutcomeCompleted (VRecord [(Ident "ok", VBool True)]) _ _ -> pure ()
            other -> expectationFailure (show other)

  it "choice + choose --select" $
    withSystemTempDirectory "hwfl-choice" $ \dir -> do
      path <- writeMod dir choiceSrc
      case loadModuleText path choiceSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "ch1",
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
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingChoice c)) _ _ _ ->
              chOptions c `shouldBe` ["staging", "prod", "abort"]
            other -> expectationFailure ("expected awaiting choice, got " <> show other)
          chosen <- chooseRun dir "ch1" "staging" mockProvider "model-catalog.json" noopObserver
          case chosen of
            OutcomeCompleted (VRecord [(Ident "env", VString "staging")]) _ _ -> pure ()
            other -> expectationFailure (show other)

  it "ask + reply --text" $
    withSystemTempDirectory "hwfl-ask" $ \dir -> do
      path <- writeMod dir askSrc
      case loadModuleText path askSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "ask1",
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
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingAsk a)) _ _ _ -> do
              askPrompt a `shouldBe` "Your name?"
              askDetail a `shouldBe` ""
            other -> expectationFailure ("expected awaiting input, got " <> show other)
          replied <- replyRun dir "ask1" "Ada" mockProvider "model-catalog.json" noopObserver
          case replied of
            OutcomeCompleted (VRecord [(Ident "answer", VString "Ada")]) _ _ -> pure ()
            other -> expectationFailure (show other)

  it "par + confirm freezes pool; approve continues" $
    withSystemTempDirectory "hwfl-parconf" $ \dir -> do
      path <- writeMod dir parConfirmSrc
      case loadModuleText path parConfirmSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "pc1",
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
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> pure ()
            other -> expectationFailure ("expected pause, got " <> show other)
          o1 <- approveRun dir "pc1" True mockProvider "model-catalog.json" noopObserver
          -- Second confirm may pause again.
          case o1 of
            OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> do
              o2 <- approveRun dir "pc1" False mockProvider "model-catalog.json" noopObserver
              case o2 of
                OutcomeCompleted (VRecord [(Ident "results", VList rs)]) _ _ ->
                  rs `shouldBe` [VBool True, VBool False]
                other -> expectationFailure (show other)
            OutcomeCompleted (VRecord [(Ident "results", VList rs)]) _ _ ->
              -- If both finished in one approve somehow.
              length rs `shouldBe` 2
            other -> expectationFailure (show other)

  it "par + ask queues replies in branch order" $
    withSystemTempDirectory "hwfl-parask" $ \dir -> do
      path <- writeMod dir parAskSrc
      case loadModuleText path parAskSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          paused <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "pa1",
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
              loaded
          case paused of
            OutcomePaused (MsPaused (PauseAwaitingAsk a)) _ _ _ ->
              askPrompt a `shouldBe` "first"
            other -> expectationFailure ("expected first ask, got " <> show other)
          second <- replyRun dir "pa1" "one" mockProvider "model-catalog.json" noopObserver
          case second of
            OutcomePaused (MsPaused (PauseAwaitingAsk a)) _ _ _ ->
              askPrompt a `shouldBe` "second"
            other -> expectationFailure ("expected second ask, got " <> show other)
          final <- replyRun dir "pa1" "two" mockProvider "model-catalog.json" noopObserver
          case final of
            OutcomeCompleted (VRecord [(Ident "results", VList values)]) _ _ ->
              values `shouldBe` [VString "one", VString "two"]
            other -> expectationFailure (show other)

  it "step then resume" $
    withSystemTempDirectory "hwfl-step" $ \dir -> do
      writeFile (dir </> "a.txt") "A"
      writeFile (dir </> "b.txt") "B"
      writeFile (dir </> "c.txt") "C"
      path <- writeMod dir parSrc
      case loadModuleText path parSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          o0 <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "s1",
                  roEntry = path,
                  roMode = StepOnce,
                  roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime, roEntryModules = mempty
                }
              loaded
          case o0 of
            OutcomePaused {} -> pure ()
            OutcomeCompleted {} -> pure () -- tiny programs may finish in one transition
            other -> expectationFailure (show other)
          final <- resumeRun dir "s1" mockProvider "model-catalog.json" noopObserver
          case final of
            OutcomeCompleted (VRecord [(Ident "texts", VList xs)]) _ _ ->
              length xs `shouldBe` 3
            OutcomePaused {} -> do
              -- still paused on explicit? continue stepping
              final2 <- resumeRun dir "s1" mockProvider "model-catalog.json" noopObserver
              case final2 of
                OutcomeCompleted (VRecord [(Ident "texts", VList xs)]) _ _ ->
                  length xs `shouldBe` 3
                other -> expectationFailure (show other)
            other -> expectationFailure (show other)

  it "stale project hash refuses resume" $
    withSystemTempDirectory "hwfl-stale" $ \dir -> do
      path <- writeMod dir confirmSrc
      case loadModuleText path confirmSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          _ <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "stale1",
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
              loaded
          -- Mutate kernel body so project_hash changes.
          writeFile path (T.unpack (T.replace "Proceed?" "Changed?" confirmSrc))
          resumed <- resumeRun dir "stale1" mockProvider "model-catalog.json" noopObserver
          case resumed of
            OutcomeFailed (ConfigErr msg) _ _ ->
              T.isInfixOf "stale project" msg `shouldBe` True
            other -> expectationFailure (show other)

  it "project confirm → approve (separate project vs workspace)" $
    withSystemTempDirectory "hwfl-proj-confirm" $ \root -> do
      let projectDir = root </> "project"
          workspaceDir = root </> "workspace"
          entryPath = projectDir </> "workflows" </> "confirm.md"
      createDirectoryIfMissing True (projectDir </> "workflows")
      createDirectoryIfMissing True workspaceDir
      writeFile
        (projectDir </> "project.json")
        ( T.unpack $
            T.unlines
              [ "{",
                "  \"name\": \"confirm-proj\",",
                "  \"version\": \"0.1.0\",",
                "  \"entrypoint\": \"workflows/confirm\"",
                "}"
              ]
        )
      writeFile entryPath (T.unpack confirmSrc)
      let req =
            (defaultDriverRunRequest projectDir workspaceDir mockProvider)
              { drrRunId = Just "proj-confirm",
                drrModelCatalog = "model-catalog.json"
              }
      result <- driverRun req
      case result of
        Right (OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _) -> do
          approved <-
            driverApprove
              workspaceDir
              "proj-confirm"
              True
              mockProvider
              "model-catalog.json"
              noopObserver
          case approved of
            OutcomeCompleted (VRecord [(Ident "ok", VBool True)]) _ _ -> pure ()
            other -> expectationFailure (show other)
        other -> expectationFailure ("expected awaiting confirm, got " <> show other)

  it "project stale hash refuses approve" $
    withSystemTempDirectory "hwfl-proj-stale" $ \root -> do
      let projectDir = root </> "project"
          workspaceDir = root </> "workspace"
          entryPath = projectDir </> "workflows" </> "confirm.md"
      createDirectoryIfMissing True (projectDir </> "workflows")
      createDirectoryIfMissing True workspaceDir
      writeFile
        (projectDir </> "project.json")
        ( T.unpack $
            T.unlines
              [ "{",
                "  \"name\": \"stale-proj\",",
                "  \"version\": \"0.1.0\",",
                "  \"entrypoint\": \"workflows/confirm\"",
                "}"
              ]
        )
      writeFile entryPath (T.unpack confirmSrc)
      let req =
            (defaultDriverRunRequest projectDir workspaceDir mockProvider)
              { drrRunId = Just "proj-stale",
                drrModelCatalog = "model-catalog.json"
              }
      _ <- driverRun req
      writeFile entryPath (T.unpack (T.replace "Proceed?" "Changed?" confirmSrc))
      approved <-
        driverApprove
          workspaceDir
          "proj-stale"
          True
          mockProvider
          "model-catalog.json"
          noopObserver
      case approved of
        OutcomeFailed (ConfigErr msg) _ _ ->
          T.isInfixOf "stale project" msg `shouldBe` True
        other -> expectationFailure (show other)

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False
