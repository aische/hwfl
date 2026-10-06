module Hwfl.Llm.ProviderSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Llm.Pricing (ModelPricing (..), ModelRates (..), loadModelPricing)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Simple (mkSimpleProviderWithCatalog, requestToTurns)
import Hwfl.Llm.Types
  (
    AssistantPart (..),
    ChatRequest (..),
    FinishReason (..),
    Message (..),
    ProviderError (..),
    Role (..),
    StreamDelta (..),
    ThinkingContent (..),
    ToolCall (..),
    Turn (..),
    ProviderResult (..),
    emptyChatRequest,
    mkProviderResult,
    mkTokenUsage,
    mkToolCall,
    providerResultText,
    turnAssistantText,
  )
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "LlmProvider" $ do
  describe "requestToTurns (M-4)" $ do
    it "joins every RoleSystem message into the system prompt" $ do
      let req =
            (emptyChatRequest "gpt-5")
              { chatMessages =
                  [ Message RoleSystem "base",
                    Message RoleUser "u1",
                    Message RoleSystem "extra",
                    Message RoleAssistant "a1",
                    Message RoleSystem "tail"
                  ]
              }
          (sys, turns) = requestToTurns req
      sys `shouldBe` Just "base\n\nextra\n\ntail"
      turns
        `shouldBe` [ TurnUser "u1",
                     turnAssistantText "a1"
                   ]

    it "does not duplicate Host-prepended chatSystem" $ do
      let req =
            (emptyChatRequest "gpt-5")
              { chatMessages =
                  [ Message RoleSystem "base",
                    Message RoleSystem "layer",
                    Message RoleUser "hi"
                  ],
                chatSystem = Just "base"
              }
          (sys, turns) = requestToTurns req
      sys `shouldBe` Just "base\n\nlayer"
      turns `shouldBe` [TurnUser "hi"]

    it "prepends chatSystem when it is not already the first RoleSystem" $ do
      let req =
            (emptyChatRequest "gpt-5")
              { chatMessages =
                  [ Message RoleSystem "layer",
                    Message RoleUser "hi"
                  ],
                chatSystem = Just "base"
              }
          (sys, _) = requestToTurns req
      sys `shouldBe` Just "base\n\nlayer"

    it "uses chatSystem as-is on the agent turns path" $ do
      let req =
            (emptyChatRequest "gpt-5")
              { chatTurns = [TurnUser "prompt"],
                chatSystem = Just "agent-sys",
                chatMessages =
                  [ Message RoleSystem "ignored",
                    Message RoleSystem "also-ignored"
                  ]
              }
          (sys, turns) = requestToTurns req
      sys `shouldBe` Just "agent-sys"
      turns `shouldBe` [TurnUser "prompt"]

  it "mock provider returns a SUMMARY reply" $ do
    let req =
          (emptyChatRequest "gpt-5")
            { chatMessages =
                [ Message RoleSystem "sys",
                  Message RoleUser "hello world document"
                ],
              chatSystem = Just "sys"
            }
    result <- mockProvider.llmChat req
    case result of
      Left err -> expectationFailure (show err)
      Right pr -> do
        pr.prContent `shouldBe` "SUMMARY: hello world document"
        llmProviderName mockProvider `shouldBe` "mock"

  it "custom mock is selectable without workflow changes" $ do
    let alt =
          mockProviderWith $ \_ ->
            Right (providerResultText ("alt") Nothing FinishStop)
    result <-
      alt.llmChat
        (emptyChatRequest "m")
          { chatMessages = [Message RoleUser "x"]
          }
    result
      `shouldBe` Right (providerResultText ("alt") Nothing FinishStop)

  it "mock fills chatResponseFormat schema with JSON object" $ do
    let schema =
          object
            [ "type" .= ("object" :: Text),
              "properties"
                .= object
                  [ "summary" .= object ["type" .= ("string" :: Text)],
                    "score" .= object ["type" .= ("integer" :: Text)]
                  ]
            ]
        req =
          (emptyChatRequest "gpt-5")
            { chatMessages = [Message RoleUser "hello world"],
              chatResponseFormat = Just schema
            }
    result <- mockProvider.llmChat req
    case result of
      Left err -> expectationFailure (show err)
      Right pr -> do
        pr.prContent `shouldSatisfy` T.isInfixOf "SUMMARY:"
        pr.prContent `shouldSatisfy` T.isInfixOf "\"score\":1"

  it "mock emits fake StreamDelta chunks when chatOnChunk is set" $ do
    ref <- newIORef ([] :: [StreamDelta])
    let req =
          (emptyChatRequest "gpt-5")
            { chatMessages = [Message RoleUser "abcdefghijklmnop"],
              chatOnChunk = Just (\d -> modifyIORef' ref (d :))
            }
    result <- mockProvider.llmChat req
    case result of
      Left err -> expectationFailure (show err)
      Right pr -> do
        chunks <- reverse <$> readIORef ref
        length chunks `shouldSatisfy` (>= 2)
        mconcat [t | DeltaText t <- chunks] `shouldBe` pr.prContent
        pr.prContent `shouldBe` "SUMMARY: abcdefghijklmnop"

  it "mock streams thinking and tool parts in order" $ do
    ref <- newIORef ([] :: [StreamDelta])
    let parts =
          [ AssistantThinking
              ThinkingContent
                { thinkingText = Just "reason12",
                  thinkingOpaque = Nothing
                },
            AssistantText "answer12",
            AssistantToolCall (mkToolCall "c1" "fs_read" (object []))
          ]
        reply _ =
          Right (mkProviderResult parts (Just (mkTokenUsage 1 1)) FinishToolCalls)
        req =
          (emptyChatRequest "gpt-5")
            { chatMessages = [Message RoleUser "x"],
              chatOnChunk = Just (\d -> modifyIORef' ref (d :))
            }
    result <- (mockProviderWith reply).llmChat req
    case result of
      Left err -> expectationFailure (show err)
      Right _ -> do
        chunks <- reverse <$> readIORef ref
        mconcat [t | DeltaReasoning t <- chunks] `shouldBe` "reason12"
        mconcat [t | DeltaText t <- chunks] `shouldBe` "answer12"
        [n | DeltaToolCall tc <- chunks, let n = tc.tcName] `shouldBe` ["fs_read"]

  it "mock does not emit chunks for object-mode requests" $ do
    ref <- newIORef (0 :: Int)
    let schema = object ["type" .= ("object" :: Text), "properties" .= object []]
        req =
          (emptyChatRequest "gpt-5")
            { chatMessages = [Message RoleUser "x"],
              chatResponseFormat = Just schema,
              chatOnChunk = Just (\_ -> modifyIORef' ref (+ 1))
            }
    _ <- mockProvider.llmChat req
    n <- readIORef ref
    n `shouldBe` 0

  describe "catalog capabilities" $ do
    it "loads legacy catalogs without capabilities" $ do
      pricingE <- loadModelPricing (catalogFixture "legacy-no-capabilities.json")
      case pricingE of
        Left err -> expectationFailure (T.unpack err)
        Right (ModelPricing rates) -> do
          Map.lookup "mistral" rates
            `shouldBe` Just
              ( ModelRates
                  { mrInputPerM = 0.0,
                    mrOutputPerM = 0.0,
                    mrCacheReadPerM = Nothing,
                    mrCacheWritePerM = Nothing
                  }
              )
      -- Simple adapter resolves the model via llm-simple; missing capabilities
      -- default to false and must not fail catalog load.
      let provider = mkSimpleProviderWithCatalog False (catalogFixture "legacy-no-capabilities.json")
          req =
            (emptyChatRequest "mistral")
              { chatMessages = [Message RoleUser "ping"]
              }
      result <- provider.llmChat req
      case result of
        Left (InvalidRequestError msg)
          | "does not support" `T.isInfixOf` msg ->
              expectationFailure $
                "legacy catalog must load without capability validation failure: "
                  <> T.unpack msg
        Left (OtherProviderError msg)
          | "Model not found" `T.isInfixOf` msg
              || "invalid model catalog" `T.isInfixOf` T.toLower msg ->
              expectationFailure (T.unpack msg)
        _ -> pure ()

    it "maps unsupported thinking capability to InvalidRequestError" $ do
      let provider =
            mkSimpleProviderWithCatalog False (catalogFixture "thinking-without-capability.json")
          req =
            (emptyChatRequest "think_no_cap")
              { chatMessages = [Message RoleUser "ping"]
              }
      result <- provider.llmChat req
      case result of
        Left (InvalidRequestError msg) -> do
          msg `shouldSatisfy` T.isInfixOf "does not support thinking"
          msg `shouldSatisfy` T.isInfixOf "mistral:latest"
        other ->
          expectationFailure $
            "expected InvalidRequestError for unsupported thinking, got: " <> show other

    it "parses checked-in catalog cache rates and capabilities-side pricing" $ do
      pricingE <- loadModelPricing "model-catalog.json"
      case pricingE of
        Left err -> expectationFailure (T.unpack err)
        Right (ModelPricing rates) -> do
          Map.lookup "haiku_4_5" rates
            `shouldBe` Just
              ( ModelRates
                  { mrInputPerM = 1.0,
                    mrOutputPerM = 5.0,
                    mrCacheReadPerM = Just 0.1,
                    mrCacheWritePerM = Just 1.25
                  }
              )
          Map.lookup "deepseek4flash" rates
            `shouldBe` Just
              ( ModelRates
                  { mrInputPerM = 0.14,
                    mrOutputPerM = 0.28,
                    mrCacheReadPerM = Just 0.0028,
                    mrCacheWritePerM = Nothing
                  }
              )

catalogFixture :: FilePath -> FilePath
catalogFixture name = "test" </> "fixtures" </> "catalogs" </> name
