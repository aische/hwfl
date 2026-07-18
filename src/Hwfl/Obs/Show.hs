-- | Human-readable run summary / span tree for @hwfl show@ (spec §07 §6).
module Hwfl.Obs.Show
  ( ShowMode (..),
    ShowOptions (..),
    showRun,
    showStore,
    formatSpanTree,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Hwfl.Llm.Pricing (attrsCostMicros, formatCostUsd)
import Hwfl.Obs.Redact (redactJson)
import Hwfl.Obs.Span (compactAttrs, spanKindText, spanStatusText)
import Hwfl.Obs.Trace
import Hwfl.Runtime.Machine (MachineStatus (..))
import Hwfl.Runtime.Snapshot
  ( RunMeta (..),
    RunSnapshot (..),
    machineToJson,
    statusText,
  )
import Hwfl.Runtime.Store
  ( RunStore,
    emptySpanFilter,
    openRun,
    readMeta,
    readSnapshot,
    readSpans,
    runRef,
    storeRunId,
  )

data ShowMode
  = ShowSummary
  | ShowTree
  | ShowSpans
  | ShowSnapshot
  deriving stock (Eq, Show)

data ShowOptions = ShowOptions
  { soWorkspace :: FilePath,
    soRunId :: Text,
    soMode :: ShowMode,
    soFilter :: Maybe Text
  }

showRun :: ShowOptions -> IO (Either Text Text)
showRun opts = do
  mStore <- openRun (runRef opts.soWorkspace opts.soRunId)
  case mStore of
    Nothing ->
      pure (Left ("no run found: " <> opts.soRunId))
    Just store -> showStore store opts.soMode opts.soFilter

-- | Format an already-open run store (used by CLI @--debug@ after run).
showStore :: RunStore -> ShowMode -> Maybe Text -> IO (Either Text Text)
showStore store mode filt = do
  mMeta <- readMeta store
  mSnap <- readSnapshot store
  records <- readSpans store emptySpanFilter
  case (mMeta, mSnap) of
    (Nothing, Nothing) ->
      pure (Left ("no run found: " <> storeRunId store))
    _ ->
      pure . Right $ case mode of
        ShowSummary ->
          formatSummary mMeta mSnap (buildSpanForest records)
        ShowTree ->
          formatSummary mMeta mSnap (buildSpanForest records)
        ShowSpans ->
          formatSpanLines (filterSpans filt records)
        ShowSnapshot ->
          formatSnapshot mSnap

formatSummary :: Maybe RunMeta -> Maybe RunSnapshot -> [SpanNode] -> Text
formatSummary mMeta mSnap forest =
  T.unlines $
    [ "run: " <> maybe "?" (.rmRunId) mMeta,
      "status: " <> maybe "?" (statusText . (.rsStatus)) mSnap,
      "entry: " <> maybe "?" (T.pack . (.rmEntry)) mMeta,
      "seq: " <> maybe "?" (T.pack . show . (.rsSeq)) mSnap,
      "cursor: " <> cursorSummary mSnap,
      "cost: " <> formatForestCost forest,
      "",
      "spans:"
    ]
      ++ formatSpanTree forest

formatForestCost :: [SpanNode] -> Text
formatForestCost forest =
  formatCostUsd (sum (map nodeCostMicros forest))

nodeCostMicros :: SpanNode -> Int
nodeCostMicros n =
  fromMaybe 0 (attrsCostMicros n.snAttrs) + sum (map nodeCostMicros n.snChildren)

cursorSummary :: Maybe RunSnapshot -> Text
cursorSummary = \case
  Nothing -> "?"
  Just snap -> case snap.rsStatus of
    MsCompleted -> "completed"
    MsFailed -> "failed"
    MsPaused _ -> "paused; last_host=" <> fromMaybe "-" snap.rsLastHost
    MsRunning -> "running; last_host=" <> fromMaybe "-" snap.rsLastHost
    MsDraining -> "draining; last_host=" <> fromMaybe "-" snap.rsLastHost

formatSpanTree :: [SpanNode] -> [Text]
formatSpanTree = concatMap (go 0)
  where
    go depth n =
      let pad = T.replicate depth "  "
          st = maybe "open" spanStatusText n.snStatus
          attrs = compactAttrs (omitCostAttrs n.snAttrs)
          cost = spanCostText n.snAttrs
          attrSuffix =
            T.unwords
              ( [cost | not (T.null cost)]
                  ++ [attrs | not (T.null attrs)]
              )
          attrPart = if T.null attrSuffix then "" else "  " <> attrSuffix
          line =
            pad
              <> "└─ "
              <> n.snName
              <> " ["
              <> spanKindText n.snKind
              <> "] "
              <> st
              <> attrPart
       in line : concatMap (go (depth + 1)) n.snChildren

spanCostText :: Aeson.Value -> Text
spanCostText attrs =
  case attrsCostMicros attrs of
    Just m | m > 0 -> formatCostUsd m
    _ -> ""

omitCostAttrs :: Aeson.Value -> Aeson.Value
omitCostAttrs = \case
  Aeson.Object km ->
    Aeson.Object (KM.delete "cost_micros" (KM.delete "cost_usd" km))
  v -> v

formatSpanLines :: [SpanRecord] -> Text
formatSpanLines =
  T.unlines
    . map
      ( \r ->
          r.srOp
            <> " "
            <> r.srId
            <> maybe "" (" " <>) r.srName
            <> maybe "" (\k -> " (" <> spanKindText k <> ")") r.srKind
            <> maybe "" (\s -> " " <> spanStatusText s) r.srStatus
            <> let a = compactAttrs r.srAttrs
                in if T.null a then "" else "  " <> a
      )

formatSnapshot :: Maybe RunSnapshot -> Text
formatSnapshot = \case
  Nothing -> "no snapshot.json"
  Just snap ->
    let machineJson = maybe Aeson.Null machineToJson snap.rsMachine
        redacted = redactJson machineJson
     in TL.toStrict (TLE.decodeUtf8 (Aeson.encode redacted))
