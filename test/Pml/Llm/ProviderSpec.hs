module Pml.Llm.ProviderSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Llm.Mock (mockProvider, mockProviderWith)
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    Message (..),
    ProviderResult (..),
    Role (..),
    emptyChatRequest,
  )
import Test.Hspec

spec :: Spec
spec = describe "LlmProvider" $ do
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
