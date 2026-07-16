-- | Pluggable LLM backend. Workflows and Eval talk only to this record.
module Hwfl.Llm.Provider
  ( LlmProvider (..),
  )
where

import Hwfl.Llm.Types (ChatRequest, ProviderError, ProviderResult)

-- | Record-of-functions so adapters (mock, llm-simple, …) stay swappable
-- without changing host or workflow code. Configured once at run start.
data LlmProvider = LlmProvider
  { -- | Single-shot chat (and agent model rounds later). Retries belong here
    -- for M4 (host records a single span attempt; see decision log).
    llmChat :: ChatRequest -> IO (Either ProviderError ProviderResult),
    -- | Short name for logs / @--llm-provider@.
    llmProviderName :: String
  }
