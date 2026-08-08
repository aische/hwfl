module Hwfl.Llm.ProviderSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Simple (requestToTurns)
import Hwfl.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    Message (..),
    ProviderResult (..),
    Role (..),
    StreamDelta (..),
    Turn (..),
    emptyChatRequest,
  )
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
                     TurnAssistant "a1" []
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
            Right
              ProviderResult
                { prContent = "alt",
                  prToolCalls = [],
                  prUsage = Nothing,
                  prFinishReason = FinishStop
                }
    result <-
      alt.llmChat
        (emptyChatRequest "m")
          { chatMessages = [Message RoleUser "x"]
          }
    result
      `shouldBe` Right
        ProviderResult
          { prContent = "alt",
            prToolCalls = [],
            prUsage = Nothing,
            prFinishReason = FinishStop
          }

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
