-- | Deterministic mock 'LlmProvider' for tests (no network).
module Pml.Llm.Mock
  ( mockProvider,
    mockProviderWith,
  )
where

import Data.Text qualified as T
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types

-- | Default mock: echoes a summary of the last user message.
mockProvider :: LlmProvider
mockProvider = mockProviderWith defaultReply

-- | Mock with a custom reply function.
mockProviderWith :: (ChatRequest -> Either ProviderError ProviderResult) -> LlmProvider
mockProviderWith reply =
  LlmProvider
    { llmChat = pure . reply,
      llmProviderName = "mock"
    }

defaultReply :: ChatRequest -> Either ProviderError ProviderResult
defaultReply req =
  let prompt = lastUserContent req.chatMessages
      content = "SUMMARY: " <> T.take 200 prompt
   in Right
        ProviderResult
          { prContent = content,
            prUsage = Just (TokenUsage 1 1),
            prFinishReason = FinishStop
          }

lastUserContent :: [Message] -> T.Text
lastUserContent ms =
  case [m.msgContent | m <- ms, m.msgRole == RoleUser] of
    [] -> ""
    xs -> last xs
