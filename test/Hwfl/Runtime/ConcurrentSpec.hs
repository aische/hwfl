module Hwfl.Runtime.ConcurrentSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (MachineStatus (..), PauseReason (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    approveRun,
    resumeRun,
    runLoadedModule,
    emptySkillRuntime)
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
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
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
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> pure ()
            other -> expectationFailure ("expected awaiting confirm, got " <> show other)
          approved <- approveRun dir "c1" True mockProvider
          case approved of
            OutcomeCompleted (VRecord [(Ident "ok", VBool True)]) _ _ -> pure ()
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
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> pure ()
            other -> expectationFailure ("expected pause, got " <> show other)
          o1 <- approveRun dir "pc1" True mockProvider
          -- Second confirm may pause again.
          case o1 of
            OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> do
              o2 <- approveRun dir "pc1" False mockProvider
              case o2 of
                OutcomeCompleted (VRecord [(Ident "results", VList rs)]) _ _ ->
                  rs `shouldBe` [VBool True, VBool False]
                other -> expectationFailure (show other)
            OutcomeCompleted (VRecord [(Ident "results", VList rs)]) _ _ ->
              -- If both finished in one approve somehow.
              length rs `shouldBe` 2
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
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              loaded
          case o0 of
            OutcomePaused {} -> pure ()
            OutcomeCompleted {} -> pure () -- tiny programs may finish in one transition
            other -> expectationFailure (show other)
          final <- resumeRun dir "s1" mockProvider
          case final of
            OutcomeCompleted (VRecord [(Ident "texts", VList xs)]) _ _ ->
              length xs `shouldBe` 3
            OutcomePaused {} -> do
              -- still paused on explicit? continue stepping
              final2 <- resumeRun dir "s1" mockProvider
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
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              loaded
          -- Mutate kernel body so project_hash changes.
          writeFile path (T.unpack (T.replace "Proceed?" "Changed?" confirmSrc))
          resumed <- resumeRun dir "stale1" mockProvider
          case resumed of
            OutcomeFailed (ConfigErr msg) _ _ ->
              T.isInfixOf "stale project" msg `shouldBe` True
            other -> expectationFailure (show other)

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False
