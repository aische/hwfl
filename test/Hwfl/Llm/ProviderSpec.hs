module Hwfl.Llm.ProviderSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Llm.Pricing (ModelPricing (..), ModelRates (..), loadModelPricing)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Simple
  ( fromLLMAssistantPart,
    fromLLMOpaque,
    mkSimpleProviderFromModel,
    mkSimpleProviderWithCatalog,
    requestToTurns,
    toLLMContentPart,
    toLLMOpaque,
    toLLMTurn,
  )
import Hwfl.Llm.Types
  ( AssistantPart (..),
    ChatRequest (..),
    FinishReason (..),
    Message (..),
    ProviderError (..),
    ProviderOpaque (..),
    ProviderResult (..),
    Role (..),
    StreamDelta (..),
    ThinkingContent (..),
    TokenUsage (..),
    ToolCall (..),
    Turn (..),
    assistantReasoning,
    assistantText,
    assistantToolCalls,
    emptyChatRequest,
    mkProviderResult,
    mkTokenUsage,
    mkToolCall,
    providerResultText,
    turnAssistantText,
  )
import LLM.Core.Types
  ( LLMGateway (..),
    StreamEvent (..),
    imageUrlPart,
    mkChatResponse,
    textPart,
    thinkingPart,
    toolCallPart,
  )
import LLM.Core.Types qualified as LLM
import LLM.Core.Usage qualified as LLMUsage
import LLM.Core.Usage (defaultPricingInfo)
import LLM.Generate
  ( ModelConfig (..),
    defaultModelCapabilities,
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

  describe "ordered assistant conversion (phase 7)" $ do
    it "converts every assistant-relevant PartBody and drops ImagePart" $ do
      let opaque =
            LLM.ProviderOpaque
              { LLM.poProvider = "anthropic",
                LLM.poModel = Just "claude-test",
                LLM.poPayload = object ["signature" .= ("raw-α" :: Text), "n" .= (7 :: Int)]
              }
          llmParts =
            [ textPart "hello",
              thinkingPart
                ( LLM.ThinkingContent
                    { LLM.thinkingText = Just "plan",
                      LLM.thinkingOpaque = Just opaque
                    }
                ),
              toolCallPart
                ( LLM.ToolCall
                    { LLM.tcId = "c1",
                      LLM.tcName = "fs_read",
                      LLM.tcArguments = object ["path" .= ("a" :: Text)],
                      LLM.tcProviderMeta =
                        Just
                          LLM.ProviderOpaque
                            { LLM.poProvider = "google",
                              LLM.poModel = Nothing,
                              LLM.poPayload = object ["thoughtSignature" .= ("sig" :: Text)]
                            }
                    }
                ),
              imageUrlPart "https://example.com/x.png"
            ]
          engine = mapMaybe fromLLMAssistantPart llmParts
      engine
        `shouldBe` [ AssistantText "hello",
                     AssistantThinking
                       ThinkingContent
                         { thinkingText = Just "plan",
                           thinkingOpaque =
                             Just
                               ProviderOpaque
                                 { poProvider = "anthropic",
                                   poModel = Just "claude-test",
                                   poPayload = object ["signature" .= ("raw-α" :: Text), "n" .= (7 :: Int)]
                                 }
                         },
                     AssistantToolCall
                       ToolCall
                         { tcId = "c1",
                           tcName = "fs_read",
                           tcArguments = object ["path" .= ("a" :: Text)],
                           tcProviderMeta =
                             Just
                               ProviderOpaque
                                 { poProvider = "google",
                                   poModel = Nothing,
                                   poPayload = object ["thoughtSignature" .= ("sig" :: Text)]
                                 }
                         }
                   ]
      map toLLMContentPart engine `shouldBe` take 3 llmParts

    it "preserves exact part order for thinking/text/tools permutations" $ do
      let meta =
            ProviderOpaque
              { poProvider = "google",
                poModel = Just "gemini",
                poPayload = object ["thoughtSignature" .= ("s" :: Text)]
              }
          tc n =
            ToolCall
              { tcId = n,
                tcName = "fs_read",
                tcArguments = object ["path" .= n],
                tcProviderMeta = Just meta
              }
          thinking =
            AssistantThinking
              ThinkingContent
                { thinkingText = Just "why",
                  thinkingOpaque =
                    Just
                      ProviderOpaque
                        { poProvider = "anthropic",
                          poModel = Nothing,
                          poPayload = object ["signature" .= ("sig" :: Text)]
                        }
                }
          orders =
            [ [thinking, AssistantText "go", AssistantToolCall (tc "1")],
              [thinking, AssistantToolCall (tc "1")],
              [ AssistantText "before",
                AssistantToolCall (tc "1"),
                AssistantText "after",
                AssistantToolCall (tc "2")
              ],
              [ AssistantToolCall (tc "1"),
                AssistantToolCall (tc "2"),
                AssistantToolCall (tc "3")
              ]
            ]
      mapM_
        ( \parts -> do
            mapMaybe fromLLMAssistantPart (map toLLMContentPart parts) `shouldBe` parts
            case toLLMTurn (TurnAssistant parts) of
              LLM.AssistantMessage cps ->
                mapMaybe fromLLMAssistantPart cps `shouldBe` parts
              other -> expectationFailure ("expected AssistantMessage, got " <> show other)
        )
        orders

    it "round-trips ProviderOpaque payload without JSON transformation" $ do
      let payload =
            object
              [ "signature" .= ("EpABCkYICxgCKkD8opaque==" :: Text),
                "nested"
                  .= object
                    [ "keep" .= ([1, 2, 3] :: [Int]),
                      "flag" .= True,
                      "nullish" .= Null
                    ]
              ]
          opaque =
            ProviderOpaque
              { poProvider = "anthropic",
                poModel = Just "claude-sonnet-4-20250514",
                poPayload = payload
              }
      fromLLMOpaque (toLLMOpaque opaque) `shouldBe` opaque
      case toLLMOpaque opaque of
        LLM.ProviderOpaque {LLM.poPayload = p} -> p `shouldBe` payload

    it "projects final response fields from ordered parts" $ do
      let parts =
            [ AssistantThinking
                ThinkingContent
                  { thinkingText = Just "reason-first",
                    thinkingOpaque = Nothing
                  },
              AssistantText "hello ",
              AssistantThinking
                ThinkingContent
                  { thinkingText = Just "ignored-for-reasoning-proj",
                    thinkingOpaque = Nothing
                  },
              AssistantText "world",
              AssistantToolCall (mkToolCall "c1" "fs_read" (object ["path" .= ("a" :: Text)])),
              AssistantToolCall (mkToolCall "c2" "search" (object ["q" .= ("x" :: Text)]))
            ]
          pr = mkProviderResult parts (Just (mkTokenUsage 3 4)) FinishToolCalls
      assistantText parts `shouldBe` "hello world"
      assistantReasoning parts `shouldBe` Just "reason-first"
      map (.tcId) (assistantToolCalls parts) `shouldBe` ["c1", "c2"]
      pr.prContent `shouldBe` "hello world"
      map (.tcId) pr.prToolCalls `shouldBe` ["c1", "c2"]
      pr.prParts `shouldBe` parts

    it "streaming callbacks do not replace final ordered parts (fixture gateway)" $ do
      chunkRef <- newIORef ([] :: [StreamDelta])
      let opaquePayload = object ["signature" .= ("must-survive" :: Text), "arr" .= ([9] :: [Int])]
          finalParts =
            [ thinkingPart
                ( LLM.ThinkingContent
                    { LLM.thinkingText = Just "final-think",
                      LLM.thinkingOpaque =
                        Just
                          LLM.ProviderOpaque
                            { LLM.poProvider = "anthropic",
                              LLM.poModel = Just "claude-test",
                              LLM.poPayload = opaquePayload
                            }
                    }
                ),
              textPart "final-answer",
              toolCallPart
                ( LLM.ToolCall
                    { LLM.tcId = "c1",
                      LLM.tcName = "fs_read",
                      LLM.tcArguments = object ["path" .= ("note.txt" :: Text)],
                      LLM.tcProviderMeta =
                        Just
                          LLM.ProviderOpaque
                            { LLM.poProvider = "google",
                              LLM.poModel = Nothing,
                              LLM.poPayload = object ["thoughtSignature" .= ("wire" :: Text)]
                            }
                    }
                )
            ]
          resp =
            mkChatResponse
              finalParts
              ( Just
                  (LLMUsage.mkUsage 10 5)
                    { LLMUsage.usageCacheReadTokens = 2,
                      LLMUsage.usageCacheCreationTokens = 1
                    }
              )
          -- Deliberately emit mismatched stream events; final respContent wins.
          gateway =
            LLMGateway
              { gwName = "fixture",
                gwGenerateText = \_ _ -> pure (Right resp),
                gwStreamText = \_ _ onEvent -> do
                  onEvent (StreamReasoningDelta "stale-think")
                  onEvent (StreamDelta "stale-text")
                  onEvent
                    ( StreamToolCall
                        (LLM.mkToolCall "stale" "fs_read" (object ["path" .= ("wrong" :: Text)]))
                    )
                  pure (Right resp),
                gwGenerateObject = \_ _ _ ->
                  pure (Left (LLM.EmptyResponse))
              }
          provider = mkSimpleProviderFromModel False (fixtureModelConfig gateway)
          req =
            (emptyChatRequest "fixture-model")
              { chatMessages = [Message RoleUser "ping"],
                chatOnChunk = Just (\d -> modifyIORef' chunkRef (d :))
              }
      result <- provider.llmChat req
      chunks <- reverse <$> readIORef chunkRef
      case result of
        Left err -> expectationFailure (show err)
        Right pr -> do
          mconcat [t | DeltaReasoning t <- chunks] `shouldBe` "stale-think"
          mconcat [t | DeltaText t <- chunks] `shouldBe` "stale-text"
          [n | DeltaToolCall tc <- chunks, let n = tc.tcName] `shouldBe` ["fs_read"]
          pr.prParts
            `shouldBe` [ AssistantThinking
                           ThinkingContent
                             { thinkingText = Just "final-think",
                               thinkingOpaque =
                                 Just
                                   ProviderOpaque
                                     { poProvider = "anthropic",
                                       poModel = Just "claude-test",
                                       poPayload = opaquePayload
                                     }
                             },
                         AssistantText "final-answer",
                         AssistantToolCall
                           ToolCall
                             { tcId = "c1",
                               tcName = "fs_read",
                               tcArguments = object ["path" .= ("note.txt" :: Text)],
                               tcProviderMeta =
                                 Just
                                   ProviderOpaque
                                     { poProvider = "google",
                                       poModel = Nothing,
                                       poPayload = object ["thoughtSignature" .= ("wire" :: Text)]
                                     }
                             }
                       ]
          pr.prContent `shouldBe` "final-answer"
          map (.tcId) pr.prToolCalls `shouldBe` ["c1"]
          case pr.prUsage of
            Just u -> do
              u.usageInputTokens `shouldBe` 10
              u.usageOutputTokens `shouldBe` 5
              u.usageCacheReadTokens `shouldBe` 2
              u.usageCacheCreationTokens `shouldBe` 1
            Nothing -> expectationFailure "expected usage"

    it "fixture gateway preserves ordered parts without network" $ do
      let parts =
            [ thinkingPart
                ( LLM.ThinkingContent
                    { LLM.thinkingText = Just "plan",
                      LLM.thinkingOpaque = Nothing
                    }
                ),
              textPart "before",
              toolCallPart (LLM.mkToolCall "a" "search" (object ["q" .= ("1" :: Text)])),
              textPart "after",
              toolCallPart (LLM.mkToolCall "b" "search" (object ["q" .= ("2" :: Text)]))
            ]
          resp = mkChatResponse parts (Just (LLMUsage.mkUsage 1 1))
          gateway =
            LLMGateway
              { gwName = "fixture",
                gwGenerateText = \_ _ -> pure (Right resp),
                gwStreamText = \_ _ _ -> pure (Right resp),
                gwGenerateObject = \_ _ _ -> pure (Left LLM.EmptyResponse)
              }
          provider = mkSimpleProviderFromModel False (fixtureModelConfig gateway)
      result <-
        provider.llmChat
          (emptyChatRequest "fixture-model")
            { chatTurns =
                [ TurnUser "q",
                  TurnAssistant
                    [ AssistantText "prior",
                      AssistantToolCall (mkToolCall "old" "fs_read" (object []))
                    ]
                ]
            }
      case result of
        Left err -> expectationFailure (show err)
        Right pr -> do
          pr.prParts
            `shouldBe` [ AssistantThinking
                           ThinkingContent
                             { thinkingText = Just "plan",
                               thinkingOpaque = Nothing
                             },
                         AssistantText "before",
                         AssistantToolCall (mkToolCall "a" "search" (object ["q" .= ("1" :: Text)])),
                         AssistantText "after",
                         AssistantToolCall (mkToolCall "b" "search" (object ["q" .= ("2" :: Text)]))
                       ]
          pr.prFinishReason `shouldBe` FinishToolCalls

catalogFixture :: FilePath -> FilePath
catalogFixture name = "test" </> "fixtures" </> "catalogs" </> name

fixtureModelConfig :: LLMGateway -> ModelConfig
fixtureModelConfig gateway =
  ModelConfig
    { mcGateway = gateway,
      mcModel = "fixture-model",
      mcPricing = defaultPricingInfo 0 0,
      mcMaxTokens = 256,
      mcTemperature = Nothing,
      mcThinking = Nothing,
      mcCapabilities = defaultModelCapabilities,
      mcRequestTimeout = Nothing,
      mcThrottleDelay = Nothing,
      mcRetryCount = 0,
      mcJitterBackoff = 1
    }
