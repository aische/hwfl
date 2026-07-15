-- | Engine-owned LLM types — never re-export llm-simple into Eval/workflows.
module Pml.Llm.Types
  ( Role (..),
    Message (..),
    ChatRequest (..),
    TokenUsage (..),
    FinishReason (..),
    ProviderResult (..),
    ProviderError (..),
    renderProviderError,
  )
where

import Data.Text (Text)

data Role
  = RoleSystem
  | RoleUser
  | RoleAssistant
  deriving stock (Eq, Show)

data Message = Message
  { msgRole :: Role,
    msgContent :: Text
  }
  deriving stock (Eq, Show)

-- | Provider-agnostic chat request (host builds this from @llm.chat@ args).
data ChatRequest = ChatRequest
  { chatMessages :: [Message],
    chatModel :: Text,
    -- | Optional JSON Schema for structured object mode (M4 chat may leave Nothing).
    chatResponseFormat :: Maybe Text
  }
  deriving stock (Eq, Show)

data TokenUsage = TokenUsage
  { usageInputTokens :: Int,
    usageOutputTokens :: Int
  }
  deriving stock (Eq, Show)

data FinishReason
  = FinishStop
  | FinishLength
  | FinishToolCalls
  | FinishOther Text
  deriving stock (Eq, Show)

data ProviderResult = ProviderResult
  { prContent :: Text,
    prUsage :: Maybe TokenUsage,
    prFinishReason :: FinishReason
  }
  deriving stock (Eq, Show)

data ProviderError
  = AuthError Text
  | RateLimitError Text
  | TimeoutError Text
  | InvalidRequestError Text
  | OtherProviderError Text
  deriving stock (Eq, Show)

renderProviderError :: ProviderError -> Text
renderProviderError = \case
  AuthError t -> "auth: " <> t
  RateLimitError t -> "rate_limit: " <> t
  TimeoutError t -> "timeout: " <> t
  InvalidRequestError t -> "invalid_request: " <> t
  OtherProviderError t -> t
