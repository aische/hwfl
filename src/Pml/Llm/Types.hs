-- | Engine-owned LLM types — never re-export llm-simple into Eval/workflows.
module Pml.Llm.Types
  ( Role (..),
    Message (..),
    ToolSpec (..),
    ToolCall (..),
    ToolResult (..),
    Turn (..),
    ChatRequest (..),
    TokenUsage (..),
    FinishReason (..),
    ProviderResult (..),
    ProviderError (..),
    renderProviderError,
    emptyChatRequest,
  )
where

import Data.Aeson (Value)
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

-- | Provider-advertised tool schema (host builds from typed function refs).
data ToolSpec = ToolSpec
  { tsName :: Text,
    tsDescription :: Text,
    tsParameters :: Value
  }
  deriving stock (Eq, Show)

data ToolCall = ToolCall
  { tcId :: Text,
    tcName :: Text,
    tcArguments :: Value
  }
  deriving stock (Eq, Show)

data ToolResult = ToolResult
  { trCallId :: Text,
    trName :: Text,
    trContent :: Text
  }
  deriving stock (Eq, Show)

-- | Multi-turn agent / chat history (mirrors provider Turns).
data Turn
  = TurnUser Text
  | TurnAssistant Text [ToolCall]
  | TurnTool [ToolResult]
  deriving stock (Eq, Show)

-- | Provider-agnostic chat request (host builds this from @llm.chat@ / agent rounds).
data ChatRequest = ChatRequest
  { -- | Simple @llm.chat@ path (system/user Messages). Ignored when 'chatTurns' is non-empty.
    chatMessages :: [Message],
    -- | Agent conversation (preferred when non-empty).
    chatTurns :: [Turn],
    -- | System prompt for agent rounds (or override for message path).
    chatSystem :: Maybe Text,
    chatModel :: Text,
    -- | Optional JSON Schema for structured object mode.
    chatResponseFormat :: Maybe Text,
    -- | Tools advertised for this request (agent model rounds).
    chatTools :: [ToolSpec]
  }
  deriving stock (Eq, Show)

emptyChatRequest :: Text -> ChatRequest
emptyChatRequest model =
  ChatRequest
    { chatMessages = [],
      chatTurns = [],
      chatSystem = Nothing,
      chatModel = model,
      chatResponseFormat = Nothing,
      chatTools = []
    }

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
    prToolCalls :: [ToolCall],
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
