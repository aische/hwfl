-- | Span model for nested run observability (spec §07).
module Hwfl.Obs.Span
  ( SpanId,
    SpanKind (..),
    SpanStatus (..),
    SpanRecord (..),
    spanKindText,
    spanStatusText,
    parseSpanKind,
    parseSpanStatus,
    filterSpansByPrefix,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T

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

-- | One open/close line from @spans.jsonl@ (cold-path readers).
data SpanRecord = SpanRecord
  { srOp :: Text,
    srId :: SpanId,
    srParentId :: Maybe SpanId,
    srName :: Maybe Text,
    srKind :: Maybe SpanKind,
    srTStart :: Maybe Text,
    srTEnd :: Maybe Text,
    srStatus :: Maybe SpanStatus,
    srAttrs :: Aeson.Value,
    srSnapshotSeq :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | Filter by name or id prefix (CLI @--filter@ / 'SpanFilter').
filterSpansByPrefix :: Maybe Text -> [SpanRecord] -> [SpanRecord]
filterSpansByPrefix Nothing = id
filterSpansByPrefix (Just pref) =
  filter
    ( \r ->
        maybe False (pref `T.isPrefixOf`) r.srName
          || pref `T.isPrefixOf` r.srId
    )

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
