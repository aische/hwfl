-- | Deterministic mock 'LlmProvider' for tests (no network).
module Pml.Llm.Mock
  ( mockProvider,
    mockProviderWith,
  )
where

import Data.Text qualified as T
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types

-- | Default mock: echoes a summary of the last user message (no tool calls).
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
  let prompt = lastUserText req
      content = "SUMMARY: " <> T.take 200 prompt
   in Right
        ProviderResult
          { prContent = content,
            prToolCalls = [],
            prUsage = Just (TokenUsage 1 1),
            prFinishReason = FinishStop
          }

lastUserText :: ChatRequest -> T.Text
lastUserText req
  | not (null req.chatTurns) =
      case [t | TurnUser t <- req.chatTurns] of
        [] -> ""
        xs -> last xs
  | otherwise =
      case [m.msgContent | m <- req.chatMessages, m.msgRole == RoleUser] of
        [] -> ""
        xs -> last xs
