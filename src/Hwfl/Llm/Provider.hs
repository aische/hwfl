-- | Pluggable LLM backend. Workflows and Eval talk only to this record.
module Hwfl.Llm.Provider
  ( LlmProvider (..),
  )
where

import Hwfl.Llm.Types (ChatRequest, ProviderError, ProviderResult)

-- | Record-of-functions so adapters (mock, llm-simple, …) stay swappable
-- without changing host or workflow code. Configured once at run start.
data LlmProvider = LlmProvider
  { -- | Chat / agent model round. When 'chatOnChunk' is set, adapters that
    -- support streaming should invoke it with progressive 'StreamDelta's
    -- before returning the final 'ProviderResult' (spec §08 §2.2).
    llmChat :: ChatRequest -> IO (Either ProviderError ProviderResult),
    -- | Short name for logs / @--llm-provider@.
    llmProviderName :: String
  }
