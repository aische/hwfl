-- | Span model for nested run observability (spec §07).
module Hwfl.Obs.Span
  ( SpanId,
    SpanKind (..),
    SpanStatus (..),
    spanKindText,
    spanStatusText,
    parseSpanKind,
    parseSpanStatus,
  )
where

import Data.Text (Text)

type SpanId = Text

data SpanKind
  = SkHost
  | SkRegion
  | SkModule
  | SkAgentRound
  | SkAgentTool
  deriving stock (Eq, Show)

data SpanStatus
  = SsOk
  | SsError
  | SsCancelled
  deriving stock (Eq, Show)

spanKindText :: SpanKind -> Text
spanKindText = \case
  SkHost -> "host"
  SkRegion -> "region"
  SkModule -> "module"
  SkAgentRound -> "agent_round"
  SkAgentTool -> "agent_tool"

spanStatusText :: SpanStatus -> Text
spanStatusText = \case
  SsOk -> "ok"
  SsError -> "error"
  SsCancelled -> "cancelled"

parseSpanKind :: Text -> Maybe SpanKind
parseSpanKind = \case
  "host" -> Just SkHost
  "region" -> Just SkRegion
  "module" -> Just SkModule
  "agent_round" -> Just SkAgentRound
  "agent_tool" -> Just SkAgentTool
  _ -> Nothing

parseSpanStatus :: Text -> Maybe SpanStatus
parseSpanStatus = \case
  "ok" -> Just SsOk
  "error" -> Just SsError
  "cancelled" -> Just SsCancelled
  _ -> Nothing
