module Pml.Llm.ProviderSpec (spec) where

import Pml.Llm.Mock (mockProvider, mockProviderWith)
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types
import Test.Hspec

spec :: Spec
spec = describe "LlmProvider" $ do
  it "mock provider returns a SUMMARY reply" $ do
    let req =
          ChatRequest
            { chatMessages =
                [ Message RoleSystem "sys",
                  Message RoleUser "hello world document"
                ],
              chatModel = "gpt-5",
              chatResponseFormat = Nothing
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
                  prUsage = Nothing,
                  prFinishReason = FinishStop
                }
    result <-
      alt.llmChat
        ChatRequest
          { chatMessages = [Message RoleUser "x"],
            chatModel = "m",
            chatResponseFormat = Nothing
          }
    result
      `shouldBe` Right
        ProviderResult
          { prContent = "alt",
            prUsage = Nothing,
            prFinishReason = FinishStop
          }
