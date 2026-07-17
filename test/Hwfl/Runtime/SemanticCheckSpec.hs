{-# LANGUAGE OverloadedStrings #-}

module Hwfl.Runtime.SemanticCheckSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Llm.Provider (LlmProvider)
import Hwfl.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    Message (..),
    ProviderError,
    ProviderResult (..),
    Role (..),
    TokenUsage (..),
    Turn (..),
  )
import Hwfl.Parse.Load (loadModule)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

checkerPath :: FilePath
checkerPath = "examples/semantic-check/workflows/main.md"

fixtureRoot :: FilePath
fixtureRoot = "test/fixtures/semantic-target"

baseInputs :: [(Ident, Value)]
baseInputs =
  [ (Ident "entry", VString "workflows/ok"),
    (Ident "mode", VString "deterministic"),
    (Ident "model", VString "mock")
  ]

runChecker :: FilePath -> [(Ident, Value)] -> Text -> LlmProvider -> IO RunOutcome
runChecker tmp inputs runId provider = do
  loaded <- loadModule checkerPath
  case loaded of
    Left diags -> expectationFailure (show diags) >> error "unreachable"
    Right m ->
      runLoadedModule
        RunOptions
          { roWorkspace = tmp,
            roProvider = provider,
            roInputs = inputs,
            roRunId = Just runId,
            roEntry = checkerPath,
            roMode = StepRun,
            roProjectHash = Nothing,
            roExec = Nothing,
            roDebug = False,
            roModelCatalog = "model-catalog.json",
            roSkillCatalog = fst emptySkillRuntime,
            roSkillModules = snd emptySkillRuntime
          }
        m

emptyPragmatic :: Aeson.Value
emptyPragmatic =
  object
    [ "illocutionary_force" .= Aeson.String "unknown",
      "felicity_violations" .= Aeson.Array V.empty,
      "contradictions" .= Aeson.Array V.empty,
      "clarity_score" .= Aeson.Number 1.0,
      "obligations" .= Aeson.Array V.empty,
      "role" .= Aeson.String "Unknown",
      "mismatched_sentences" .= Aeson.Array V.empty
    ]

pragmaticObject ::
  Text ->
  Aeson.Array ->
  Aeson.Array ->
  Double ->
  Aeson.Array ->
  Text ->
  Aeson.Array ->
  Aeson.Value
pragmaticObject force felicity contradictions score obligations role mismatches =
  object
    [ "illocutionary_force" .= Aeson.String force,
      "felicity_violations" .= Aeson.Array felicity,
      "contradictions" .= Aeson.Array contradictions,
      "clarity_score" .= Aeson.Number (realToFrac score),
      "obligations" .= Aeson.Array obligations,
      "role" .= Aeson.String role,
      "mismatched_sentences" .= Aeson.Array mismatches
    ]

obligationRow :: Text -> Text -> Text -> Text -> Text -> Aeson.Value
obligationRow actor modality action obj quote =
  object
    [ "actor" .= Aeson.String actor,
      "modality" .= Aeson.String modality,
      "action" .= Aeson.String action,
      "object" .= Aeson.String obj,
      "condition" .= Aeson.String "",
      "quote" .= Aeson.String quote
    ]

roleMismatch :: Text -> Text -> Aeson.Value
roleMismatch quote why =
  object
    [ "quote" .= Aeson.String quote,
      "why" .= Aeson.String why
    ]

-- | Many distinct obligations (stress pair-scan / stamp caps).
chattyObligationsReply :: ChatRequest -> Either ProviderError ProviderResult
chattyObligationsReply _req =
  let obs =
        V.fromList
          [ obligationRow
              "agent"
              (if even i then "must" else "must_not")
              ("act-" <> T.pack (show i))
              ("obj-" <> T.pack (show i))
              ("quote " <> T.pack (show i))
            | i <- [1 :: Int .. 40]
          ]
      body =
        pragmaticObject
          "directive"
          V.empty
          V.empty
          0.7
          obs
          "Policy"
          V.empty
   in Right
        ProviderResult
          { prContent = TE.decodeUtf8 (BL.toStrict (encode body)),
            prToolCalls = [],
            prUsage = Just (TokenUsage 1 1),
            prFinishReason = FinishStop
          }

-- | Planted conflicts / obligations / role mismatches; else empty lists.
conflictAwareReply :: ChatRequest -> Either ProviderError ProviderResult
conflictAwareReply req =
  let prompt = lastUserText req
      body
        | T.isInfixOf "GHC2021" prompt && T.isInfixOf "Haskell2010" prompt =
            pragmaticObject
              "directive"
              V.empty
              ( V.singleton $
                  object
                    [ "quote_a" .= Aeson.String "Pin the project to GHC2021 for all modules.",
                      "quote_b" .= Aeson.String "Always use Haskell2010 as the language standard.",
                      "why" .= Aeson.String "Cannot pin both GHC2021 and Haskell2010"
                    ]
              )
              0.5
              V.empty
              "Policy"
              V.empty
        | T.isInfixOf "must never skip skill.load before the first write" prompt =
            pragmaticObject
              "assertive"
              V.empty
              V.empty
              0.6
              V.empty
              "Example"
              ( V.singleton $
                  roleMismatch
                    "The agent must never skip skill.load before the first write."
                    "Hard constraint inside an Example section"
              )
        | T.isInfixOf "must use lib/search for all catalog lookups" prompt =
            pragmaticObject
              "directive"
              V.empty
              V.empty
              0.8
              ( V.singleton $
                  obligationRow
                    "agent"
                    "must"
                    "use"
                    "lib/search"
                    "The agent must use lib/search for all catalog lookups."
              )
              "Policy"
              V.empty
        | T.isInfixOf "must not use lib/search under any circumstance" prompt =
            pragmaticObject
              "directive"
              V.empty
              V.empty
              0.8
              ( V.singleton $
                  obligationRow
                    "agent"
                    "must_not"
                    "use"
                    "lib/search"
                    "The agent must not use lib/search under any circumstance."
              )
              "Policy"
              V.empty
        | T.isInfixOf "must load skills/does-not-exist before any edit" prompt =
            pragmaticObject
              "directive"
              V.empty
              V.empty
              0.8
              ( V.singleton $
                  obligationRow
                    "agent"
                    "must"
                    "load"
                    "skills/does-not-exist"
                    "The agent must load skills/does-not-exist before any edit."
              )
              "Policy"
              V.empty
        | otherwise = emptyPragmatic
   in Right
        ProviderResult
          { prContent = TE.decodeUtf8 (BL.toStrict (encode body)),
            prToolCalls = [],
            prUsage = Just (TokenUsage 1 1),
            prFinishReason = FinishStop
          }

lastUserText :: ChatRequest -> Text
lastUserText req
  | not (null req.chatTurns) =
      case [t | TurnUser t <- req.chatTurns] of
        [] -> ""
        xs -> last xs
  | otherwise =
      case [m.msgContent | m <- req.chatMessages, m.msgRole == RoleUser] of
        [] -> ""
        xs -> last xs

spec :: Spec
spec = describe "semantic-check dogfood (M8 / E20 deepen)" $ do
  it "type-checks as a single module" $ do
    loaded <- loadModule checkerPath
    case loaded of
      Left diags -> expectationFailure (show diags)
      Right m -> checkLoadedModule m `shouldSatisfy` isRight

  it "reviews fixture: structural, prose, quoted redundancy, policy gate shape" $
    withSystemTempDirectory "hwfl-semcheck" $ \tmp -> do
      copyTree fixtureRoot tmp
      outcome <- runChecker tmp baseInputs "e20" mockProvider
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          case lookup (Ident "finding_count") fs of
            Just (VInt n) -> n `shouldSatisfy` (> 0)
            other -> expectationFailure ("finding_count: " <> show other)
          doesFileExist (tmp </> ".hwfl/runs/e20/semantic-report.json") `shouldReturn` True
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"schema\""
          report `shouldSatisfy` T.isInfixOf "workflows/missing"
          report `shouldSatisfy` T.isInfixOf "tools/helper"
          report `shouldSatisfy` T.isInfixOf "\"review_gate\""
          report `shouldSatisfy` T.isInfixOf "check_dead_reference"
          report `shouldSatisfy` T.isInfixOf "check_internal_conflict"
          report `shouldSatisfy` T.isInfixOf "\"category\":\"redundancy\""
          report `shouldSatisfy` T.isInfixOf "Always prefer exact matches"
          report `shouldSatisfy` T.isInfixOf "\"mode\":\"deterministic\""
          report `shouldSatisfy` T.isInfixOf "\"pragmatic_findings\":[]"
          report `shouldSatisfy` (not . T.isInfixOf "\"evidence\":\"/\"")
          report `shouldSatisfy` (not . T.isInfixOf "README.md")
        other -> expectationFailure ("expected completed run, got: " <> show other)

  it "pragmatic mode quotes planted GHC2021 vs Haskell2010 conflict" $
    withSystemTempDirectory "hwfl-semcheck-prag" $ \tmp -> do
      copyTree fixtureRoot tmp
      let inputs =
            [ (Ident "entry", VString "workflows/ok"),
              (Ident "mode", VString "pragmatic"),
              (Ident "model", VString "mock")
            ]
          provider = mockProviderWith conflictAwareReply
      outcome <- runChecker tmp inputs "e20p" provider
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20p/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"mode\":\"pragmatic\""
          report `shouldSatisfy` T.isInfixOf "check_internal_conflict"
          report `shouldSatisfy` T.isInfixOf "\"category\":\"contradiction\""
          report `shouldSatisfy` T.isInfixOf "GHC2021"
          report `shouldSatisfy` T.isInfixOf "Haskell2010"
          report `shouldSatisfy` (not . T.isInfixOf "\"pragmatic_findings\":[]")
        other -> expectationFailure ("expected completed run, got: " <> show other)

  it "pragmatic mode builds obligation graph (must/must_not + dead catalog)" $
    withSystemTempDirectory "hwfl-semcheck-obl" $ \tmp -> do
      copyTree fixtureRoot tmp
      let inputs =
            [ (Ident "entry", VString "workflows/ok"),
              (Ident "mode", VString "pragmatic"),
              (Ident "model", VString "mock")
            ]
          provider = mockProviderWith conflictAwareReply
      outcome <- runChecker tmp inputs "e20o" provider
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20o/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"obligations\""
          report `shouldSatisfy` T.isInfixOf "\"category\":\"obligation\""
          report `shouldSatisfy` T.isInfixOf "must vs must_not"
          report `shouldSatisfy` T.isInfixOf "lib/search"
          report `shouldSatisfy` T.isInfixOf "skills/does-not-exist"
          report `shouldSatisfy` T.isInfixOf "absent from the catalog"
        other -> expectationFailure ("expected completed run, got: " <> show other)

  it "pragmatic mode survives chatty obligation extracts without crunch trap" $
    withSystemTempDirectory "hwfl-semcheck-chatty" $ \tmp -> do
      copyTree fixtureRoot tmp
      let inputs =
            [ (Ident "entry", VString "workflows/ok"),
              (Ident "mode", VString "pragmatic"),
              (Ident "model", VString "mock")
            ]
          provider = mockProviderWith chattyObligationsReply
      outcome <- runChecker tmp inputs "e20c" provider
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20c/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"obligations\""
          report `shouldSatisfy` (not . T.isInfixOf "pure crunch limit")
        other -> expectationFailure ("expected completed run, got: " <> show other)

  it "pragmatic mode flags hard constraint inside Example role (S1)" $
    withSystemTempDirectory "hwfl-semcheck-role" $ \tmp -> do
      copyTree fixtureRoot tmp
      let inputs =
            [ (Ident "entry", VString "workflows/ok"),
              (Ident "mode", VString "pragmatic"),
              (Ident "model", VString "mock")
            ]
          provider = mockProviderWith conflictAwareReply
      outcome <- runChecker tmp inputs "e20r" provider
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20r/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"roles\""
          report `shouldSatisfy` T.isInfixOf "\"role\":\"Example\""
          report `shouldSatisfy` T.isInfixOf "\"category\":\"role\""
          report `shouldSatisfy` T.isInfixOf "must never skip skill.load"
          report `shouldSatisfy` T.isInfixOf "example-hard-rule"
        other -> expectationFailure ("expected completed run, got: " <> show other)

copyTree :: FilePath -> FilePath -> IO ()
copyTree src dst = do
  createDirectoryIfMissing True (dst </> "workflows")
  createDirectoryIfMissing True (dst </> "lib")
  createDirectoryIfMissing True (dst </> "skills")
  mapM_
    ( \rel -> copyFile (src </> rel) (dst </> rel)
    )
    [ "workflows/ok.md",
      "workflows/bad.md",
      "lib/search.md",
      "skills/conflict-lang.md",
      "skills/require-search.md",
      "skills/forbid-search.md",
      "skills/ghost-tool.md",
      "skills/example-hard-rule.md"
    ]
