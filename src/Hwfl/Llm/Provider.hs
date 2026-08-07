-- | Pluggable LLM backend. Workflows and Eval talk only to this record.
module Hwfl.Llm.Provider
  ( LlmProvider (..),
    safeLlmChat,
  )
where

import Hwfl.Exception (describeException, trySync)
import Hwfl.Llm.Types (ChatRequest, ProviderError (..), ProviderResult)

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

-- | 'llmChat' with synchronous exceptions turned into a 'ProviderError'.
--
-- Adapters do network I/O and JSON decoding; a socket reset or a bad response
-- throws rather than returning 'Left'. Every runtime call site uses this
-- wrapper so a provider crash fails the model round instead of the process.
safeLlmChat :: LlmProvider -> ChatRequest -> IO (Either ProviderError ProviderResult)
safeLlmChat provider req = do
  r <- trySync (provider.llmChat req)
  pure $ case r of
    Right res -> res
    Left ex -> Left (OtherProviderError ("provider threw: " <> describeException ex))
