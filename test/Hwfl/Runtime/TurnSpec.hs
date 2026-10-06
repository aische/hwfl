module Hwfl.Runtime.TurnSpec (spec) where

import Data.Aeson (Value (..), eitherDecodeFileStrict', object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Vector qualified as Vec
import Hwfl.Eval.Value qualified as V
import Hwfl.Json.Encode (valueToAeson)
import Hwfl.Llm.Types
  ( AssistantPart (..),
    ProviderOpaque (..),
    ThinkingContent (..),
    ToolCall (..),
    Turn (..),
    mkToolCall,
    turnAssistantText,
    turnAssistantTextTools,
  )
import Hwfl.Runtime.Agent (initAgentState)
import Hwfl.Runtime.Context (ConsolidateMode (..))
import Hwfl.Runtime.Machine
  ( AgentState (..),
    Current (..),
    Machine (..),
    MachineStatus (..),
    PauseReason (..),
    initialMachine,
  )
import Hwfl.Runtime.Snapshot (machineFromJson, machineToJson)
import Hwfl.Runtime.Turn
  ( parseAssistantPart,
    parseTurn,
    turnToJson,
    turnToPublicJson,
  )
import System.FilePath ((</>))
import Test.Hspec

fixture :: FilePath -> FilePath
fixture name = "test" </> "fixtures" </> "turns" </> name

loadTurn :: FilePath -> IO (Either String Turn)
loadTurn path = do
  ev <- eitherDecodeFileStrict' path
  pure (ev >>= parseEither parseTurn)

spec :: Spec
spec = describe "turn JSON migration (phase 4)" $ do
  describe "legacy decode" $ do
    it "decodes old text-only assistant turns" $ do
      loaded <- loadTurn (fixture "old-text-only.json")
      loaded `shouldBe` Right (turnAssistantText "hello world")

    it "decodes old text-plus-tools into text-then-calls order" $ do
      loaded <- loadTurn (fixture "old-text-plus-tools.json")
      loaded
        `shouldBe` Right
          ( turnAssistantTextTools
              "I will read the file"
              [mkToolCall "call_1" "fs_read" (object ["path" .= ("note.txt" :: Text)])]
          )

  describe "canonical parts" $ do
    it "decodes ordered thinking/text/tool-call turns" $ do
      loaded <- loadTurn (fixture "ordered-thinking-text-tools.json")
      loaded
        `shouldBe` Right
          ( TurnAssistant
              [ AssistantThinking
                  ThinkingContent
                    { thinkingText = Just "plan the steps",
                      thinkingOpaque = Nothing
                    },
                AssistantText "reading note.txt",
                AssistantToolCall (mkToolCall "c1" "fs_read" (object ["path" .= ("note.txt" :: Text)]))
              ]
          )

    it "round-trips Claude opaque thinking payload without transformation" $ do
      loaded <- loadTurn (fixture "claude-opaque-thinking.json")
      case loaded of
        Left err -> expectationFailure err
        Right turn -> do
          parseEither parseTurn (turnToJson turn) `shouldBe` Right turn
          case turn of
            TurnAssistant
              [ AssistantThinking
                  ThinkingContent
                    { thinkingOpaque = Just opaque
                    },
                AssistantText "done"
                ] -> do
                opaque.poProvider `shouldBe` "anthropic"
                opaque.poModel `shouldBe` Just "claude-sonnet-4-20250514"
                case opaque.poPayload of
                  Object km -> do
                    KM.lookup "signature" km
                      `shouldBe` Just (String "EpABCkYICxgCKkD8opaque-signature-bytes-must-roundtrip==")
                    KM.lookup "nested" km
                      `shouldBe` Just
                        ( object
                            [ "keep" .= ([1, 2, 3] :: [Int]),
                              "flag" .= True
                            ]
                        )
                  other -> expectationFailure ("expected object payload, got " <> show other)
            other -> expectationFailure ("unexpected turn: " <> show other)

    it "round-trips Gemini tool-call provider_meta" $ do
      loaded <- loadTurn (fixture "gemini-tool-meta.json")
      case loaded of
        Left err -> expectationFailure err
        Right turn -> do
          parseEither parseTurn (turnToJson turn) `shouldBe` Right turn
          case turn of
            TurnAssistant [AssistantText _, AssistantToolCall tc] -> do
              case tc.tcProviderMeta of
                Just meta -> do
                  meta.poProvider `shouldBe` "google"
                  meta.poModel `shouldBe` Just "gemini-2.5-pro"
                  meta.poPayload
                    `shouldBe` object
                      [ "thoughtSignature"
                          .= ("CiYBAGFzZGZnaGprbG1ub3BxcnN0dXZ3eHl6MTIzNDU2Nzg5MA==" :: Text)
                      ]
                Nothing -> expectationFailure "expected provider_meta"
            other -> expectationFailure ("unexpected turn: " <> show other)

    it "rejects unknown/invalid part tags" $ do
      loaded <- loadTurn (fixture "invalid-part-tag.json")
      case loaded of
        Left err -> err `shouldContain` "unknown assistant part"
        Right t -> expectationFailure ("expected rejection, got " <> show t)

    it "rejects unknown part tags in isolation" $
      parseEither parseAssistantPart (object ["tag" .= ("audio" :: Text)])
        `shouldSatisfy` isLeft

  describe "pause/resume machine codec" $ do
    it "preserves opaque JSON values through machine snapshot round-trip" $ do
      let payload =
            object
              [ "signature" .= ("raw-bytes-αβγ" :: Text),
                "arr" .= ([True, False] :: [Bool]),
                "n" .= (42 :: Int)
              ]
          opaque =
            ProviderOpaque
              { poProvider = "anthropic",
                poModel = Just "claude-test",
                poPayload = payload
              }
          geminiMeta =
            ProviderOpaque
              { poProvider = "google",
                poModel = Nothing,
                poPayload = object ["thoughtSignature" .= ("sig" :: Text)]
              }
          parts =
            [ AssistantThinking
                ThinkingContent
                  { thinkingText = Just "think",
                    thinkingOpaque = Just opaque
                  },
              AssistantText "go",
              AssistantToolCall
                ToolCall
                  { tcId = "t1",
                    tcName = "fs_read",
                    tcArguments = object ["path" .= ("x" :: Text)],
                    tcProviderMeta = Just geminiMeta
                  }
            ]
          prior = [TurnUser "q", TurnAssistant parts]
          ag =
            initAgentState
              "sys"
              "prompt"
              []
              "model"
              4
              "span"
              Nothing
              prior
              Nothing
              Nothing
              ConsolidateOff
              32
              2000
          hist = ag.agHistory
          machine =
            (initialMachine "project" (CurAgent ag))
              { mStatus = MsPaused PauseExplicit
              }
      case machineFromJson (machineToJson machine) of
        Left err -> expectationFailure err
        Right machine' ->
          case machine'.mCurrent of
            CurAgent ag' -> do
              ag'.agHistory `shouldBe` hist
              -- Opaque payloads survive encode/decode structurally.
              case ag'.agHistory of
                [TurnUser _, TurnAssistant restoredParts, TurnUser _] ->
                  restoredParts `shouldBe` parts
                other ->
                  expectationFailure ("unexpected history shape: " <> show other)
            other -> expectationFailure ("expected CurAgent, got " <> show other)

  describe "author-facing encoding" $ do
    it "does not expose opaque payloads on VTurn JSON" $ do
      let parts =
            [ AssistantThinking
                ThinkingContent
                  { thinkingText = Just "plan",
                    thinkingOpaque =
                      Just
                        ProviderOpaque
                          { poProvider = "anthropic",
                            poModel = Nothing,
                            poPayload = object ["secret" .= ("MUST_NOT_LEAK" :: Text)]
                          }
                  },
              AssistantText "ok",
              AssistantToolCall
                ToolCall
                  { tcId = "c",
                    tcName = "fs_read",
                    tcArguments = object ["path" .= ("a" :: Text)],
                    tcProviderMeta =
                      Just
                        ProviderOpaque
                          { poProvider = "google",
                            poModel = Nothing,
                            poPayload = object ["thoughtSignature" .= ("LEAK" :: Text)]
                          }
                  }
            ]
          turn = TurnAssistant parts
          public = turnToPublicJson turn
      case valueToAeson (V.VTurn turn) of
        Left err -> expectationFailure (show err)
        Right encoded -> do
          encoded `shouldBe` public
          show encoded `shouldNotContain` "MUST_NOT_LEAK"
          show encoded `shouldNotContain` "LEAK"
          show encoded `shouldNotContain` "thinking_opaque"
          show encoded `shouldNotContain` "provider_meta"
          show encoded `shouldContain` "plan"
          show encoded `shouldContain` "ok"

    it "writes the canonical parts shape (not legacy text/calls)" $ do
      let encoded = turnToJson (turnAssistantText "hi")
      case encoded of
        Object km -> do
          KM.member "parts" km `shouldBe` True
          KM.member "text" km `shouldBe` False
          KM.member "calls" km `shouldBe` False
        other -> expectationFailure ("expected object, got " <> show other)

    it "resumes legacy assistant history and rewrites it in the new parts format" $ do
      loaded <- loadTurn (fixture "old-text-plus-tools.json")
      let expected =
            turnAssistantTextTools
              "I will read the file"
              [mkToolCall "call_1" "fs_read" (object ["path" .= ("note.txt" :: Text)])]
      loaded `shouldBe` Right expected
      let ag =
            initAgentState
              "sys"
              "prompt"
              []
              "model"
              4
              "span"
              Nothing
              [expected]
              Nothing
              Nothing
              ConsolidateOff
              32
              2000
          machine =
            (initialMachine "project" (CurAgent ag))
              { mStatus = MsPaused PauseExplicit
              }
          -- Simulate an on-disk snapshot that still uses the legacy
          -- assistant JSON shape inside agent history.
          legacyHistoryJson =
            [ object
                [ "tag" .= ("assistant" :: Text),
                  "text" .= ("I will read the file" :: Text),
                  "calls"
                    .= [ object
                           [ "id" .= ("call_1" :: Text),
                             "name" .= ("fs_read" :: Text),
                             "arguments" .= object ["path" .= ("note.txt" :: Text)]
                           ]
                       ]
                ],
              object ["tag" .= ("user" :: Text), "text" .= ("prompt" :: Text)]
            ]
      case machineToJson machine of
        Object mkm ->
          case KM.lookup "current" mkm of
            Just (Object ckm) ->
              case KM.lookup "agent" ckm of
                Just (Object akm) -> do
                  let patchedAgent = Object (KM.insert "history" (Array (Vec.fromList legacyHistoryJson)) akm)
                      patchedCurrent = Object (KM.insert "agent" patchedAgent ckm)
                      patchedMachine = Object (KM.insert "current" patchedCurrent mkm)
                  case machineFromJson patchedMachine of
                    Left err -> expectationFailure err
                    Right machine' -> do
                      case machine'.mCurrent of
                        CurAgent ag' ->
                          ag'.agHistory `shouldBe` [expected, TurnUser "prompt"]
                        other -> expectationFailure ("expected CurAgent, got " <> show other)
                      case machineToJson machine' of
                        Object mkm' ->
                          case KM.lookup "current" mkm' of
                            Just (Object ckm') ->
                              case KM.lookup "agent" ckm' of
                                Just (Object akm') ->
                                  case KM.lookup "history" akm' of
                                    Just (Array hist) -> do
                                      length hist `shouldBe` 2
                                      case hist Vec.! 0 of
                                        Object turnKm -> do
                                          KM.member "parts" turnKm `shouldBe` True
                                          KM.member "text" turnKm `shouldBe` False
                                          KM.member "calls" turnKm `shouldBe` False
                                        other ->
                                          expectationFailure ("expected assistant object, got " <> show other)
                                    other -> expectationFailure ("expected history array, got " <> show other)
                                _ -> expectationFailure "expected agent object after rewrite"
                            _ -> expectationFailure "expected current object after rewrite"
                        _ -> expectationFailure "expected machine object after rewrite"
                _ -> expectationFailure "expected agent object"
            _ -> expectationFailure "expected current object"
        _ -> expectationFailure "expected machine object"
