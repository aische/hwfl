-- | Engine-owned LLM types — never re-export llm-simple into Eval/workflows.
module Hwfl.Llm.Types
  ( Role (..),
    Message (..),
    ToolSpec (..),
    ToolCall (..),
    mkToolCall,
    ToolResult (..),
    ProviderOpaque (..),
    ThinkingContent (..),
    AssistantPart (..),
    Turn (..),
    turnAssistantText,
    turnAssistantTextTools,
    assistantText,
    assistantReasoning,
    assistantToolCalls,
    StreamDelta (..),
    ChatRequest (..),
    TokenUsage (..),
    mkTokenUsage,
    FinishReason (..),
    ProviderResult (..),
    mkProviderResult,
    providerResultText,
    providerResultTextTools,
    ProviderError (..),
    renderProviderError,
    finishReasonText,
    emptyChatRequest,
  )
where

import Data.Aeson (Value)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T

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

-- | Opaque, provider-owned payload that must round-trip for replay.
--
-- Replay state only — not author-controlled workflow data. Persist losslessly;
-- do not print in transcripts or copy into tool results.
data ProviderOpaque = ProviderOpaque
  { poProvider :: Text,
    poModel :: Maybe Text,
    poPayload :: Value
  }
  deriving stock (Eq, Show)

-- | Displayable and/or opaque thinking content for one assistant part.
data ThinkingContent = ThinkingContent
  { thinkingText :: Maybe Text,
    thinkingOpaque :: Maybe ProviderOpaque
  }
  deriving stock (Eq, Show)

data ToolCall = ToolCall
  { tcId :: Text,
    tcName :: Text,
    tcArguments :: Value,
    -- | Opaque provider metadata (e.g. Gemini thought signatures).
    tcProviderMeta :: Maybe ProviderOpaque
  }
  deriving stock (Eq, Show)

-- | Tool call with no provider metadata.
mkToolCall :: Text -> Text -> Value -> ToolCall
mkToolCall tid name args =
  ToolCall
    { tcId = tid,
      tcName = name,
      tcArguments = args,
      tcProviderMeta = Nothing
    }

data ToolResult = ToolResult
  { trCallId :: Text,
    trName :: Text,
    trContent :: Text
  }
  deriving stock (Eq, Show)

-- | One ordered part of an assistant turn. Authoritative for replay.
data AssistantPart
  = AssistantText Text
  | AssistantThinking ThinkingContent
  | AssistantToolCall ToolCall
  deriving stock (Eq, Show)

-- | Multi-turn agent / chat history (mirrors provider Turns).
data Turn
  = TurnUser Text
  | TurnAssistant [AssistantPart]
  | TurnTool [ToolResult]
  deriving stock (Eq, Show)

-- | Text-only assistant turn (omits an empty text part).
turnAssistantText :: Text -> Turn
turnAssistantText t = TurnAssistant (canonicalTextParts t)

-- | Canonical text-then-tool-calls assistant turn.
--
-- Text first when non-empty, followed by tool calls. Does not recover an
-- arbitrary provider part order — use 'TurnAssistant' with authoritative parts
-- when replaying.
turnAssistantTextTools :: Text -> [ToolCall] -> Turn
turnAssistantTextTools t calls =
  TurnAssistant (canonicalTextParts t ++ map AssistantToolCall calls)

-- | Concatenate text parts in order.
assistantText :: [AssistantPart] -> Text
assistantText = T.concat . mapMaybe go
  where
    go = \case
      AssistantText t -> Just t
      _ -> Nothing

-- | First non-empty thinking text, if any.
assistantReasoning :: [AssistantPart] -> Maybe Text
assistantReasoning = go
  where
    go [] = Nothing
    go (AssistantThinking tc : rest) =
      case tc.thinkingText of
        Just t | not (T.null t) -> Just t
        _ -> go rest
    go (_ : rest) = go rest

-- | Tool calls in part order.
assistantToolCalls :: [AssistantPart] -> [ToolCall]
assistantToolCalls = mapMaybe go
  where
    go = \case
      AssistantToolCall tc -> Just tc
      _ -> Nothing

canonicalTextParts :: Text -> [AssistantPart]
canonicalTextParts t
  | T.null t = []
  | otherwise = [AssistantText t]

-- | Progressive provider delta (obs side channel only — not a language value).
data StreamDelta
  = -- | Answer / preamble / unclassified text partial.
    DeltaText Text
  | -- | Chain-of-thought / reasoning partial (when the provider emits it).
    DeltaReasoning Text
  | -- | Complete tool call (no fragment-level arg streaming).
    DeltaToolCall ToolCall
  deriving stock (Eq, Show)

-- | Provider-agnostic chat request (host builds this from @llm.chat@ / agent rounds).
-- No Eq/Show: @chatOnChunk@ is an IO hook.
data ChatRequest = ChatRequest
  { -- | Simple @llm.chat@ path (system/user Messages). Ignored when 'chatTurns' is non-empty.
    chatMessages :: [Message],
    -- | Agent conversation (preferred when non-empty).
    chatTurns :: [Turn],
    -- | System prompt for agent rounds (or override for message path).
    chatSystem :: Maybe Text,
    chatModel :: Text,
    -- | Optional JSON Schema for structured object mode (@llm.object@).
    chatResponseFormat :: Maybe Value,
    -- | Tools advertised for this request (agent model rounds).
    chatTools :: [ToolSpec],
    -- | Optional progressive hook (provider → host obs). Ignored by adapters
    -- without stream support; structured object mode need not invoke it.
    chatOnChunk :: Maybe (StreamDelta -> IO ())
  }

emptyChatRequest :: Text -> ChatRequest
emptyChatRequest model =
  ChatRequest
    { chatMessages = [],
      chatTurns = [],
      chatSystem = Nothing,
      chatModel = model,
      chatResponseFormat = Nothing,
      chatTools = [],
      chatOnChunk = Nothing
    }

-- | Token usage from a provider call.
--
-- 'usageInputTokens' is the total input count (including cache read/creation).
-- Cache counters are zero when the provider does not report them.
data TokenUsage = TokenUsage
  { usageInputTokens :: Int,
    usageOutputTokens :: Int,
    usageCacheReadTokens :: Int,
    usageCacheCreationTokens :: Int
  }
  deriving stock (Eq, Show)

-- | Construct usage with zero cache counters.
mkTokenUsage :: Int -> Int -> TokenUsage
mkTokenUsage input output =
  TokenUsage
    { usageInputTokens = input,
      usageOutputTokens = output,
      usageCacheReadTokens = 0,
      usageCacheCreationTokens = 0
    }

data FinishReason
  = FinishStop
  | FinishLength
  | FinishToolCalls
  | FinishOther Text
  deriving stock (Eq, Show)

finishReasonText :: FinishReason -> Text
finishReasonText = \case
  FinishStop -> "stop"
  FinishLength -> "length"
  FinishToolCalls -> "tool_calls"
  FinishOther t -> t

-- | Provider reply. Ordered 'prParts' are authoritative; 'prContent' and
-- 'prToolCalls' are derived projections and must not be set independently.
data ProviderResult = ProviderResult
  { prParts :: [AssistantPart],
    prContent :: Text,
    prToolCalls :: [ToolCall],
    prUsage :: Maybe TokenUsage,
    prFinishReason :: FinishReason
  }
  deriving stock (Eq, Show)

-- | Build a result from authoritative ordered parts.
mkProviderResult :: [AssistantPart] -> Maybe TokenUsage -> FinishReason -> ProviderResult
mkProviderResult parts usage finish =
  ProviderResult
    { prParts = parts,
      prContent = assistantText parts,
      prToolCalls = assistantToolCalls parts,
      prUsage = usage,
      prFinishReason = finish
    }

-- | Text-only result (one text part when non-empty).
providerResultText :: Text -> Maybe TokenUsage -> FinishReason -> ProviderResult
providerResultText t = mkProviderResult (canonicalTextParts t)

-- | Canonical text-then-tool-calls result.
providerResultTextTools :: Text -> [ToolCall] -> Maybe TokenUsage -> FinishReason -> ProviderResult
providerResultTextTools t calls =
  mkProviderResult (canonicalTextParts t ++ map AssistantToolCall calls)

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
