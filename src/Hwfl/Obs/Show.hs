-- | Human-readable run summary / span tree for @hwfl show@ (spec §07 §6).
module Hwfl.Obs.Show
  ( ShowMode (..),
    ShowOptions (..),
    showRun,
    formatSpanTree,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Hwfl.Obs.Redact (redactJson)
import Hwfl.Obs.Span (spanKindText, spanStatusText)
import Hwfl.Obs.Trace
import Hwfl.Runtime.Machine (MachineStatus (..))
import Hwfl.Runtime.Snapshot
  ( RunMeta (..),
    RunSnapshot (..),
    RunStore (..),
    machineToJson,
    openRunStore,
    readRunMeta,
    readRunSnapshot,
    statusText,
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
  store <- openRunStore opts.soWorkspace opts.soRunId
  mMeta <- readRunMeta store
  mSnap <- readRunSnapshot store
  records <- readSpanRecords store
  case (mMeta, mSnap) of
    (Nothing, Nothing) ->
      pure (Left ("no run found at " <> T.pack (store.storeRoot)))
    _ ->
      pure . Right $ case opts.soMode of
        ShowSummary ->
          formatSummary mMeta mSnap (buildSpanForest records)
        ShowTree ->
          formatSummary mMeta mSnap (buildSpanForest records)
        ShowSpans ->
          formatSpanLines (filterSpans opts.soFilter records)
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
      "",
      "spans:"
    ]
      ++ formatSpanTree forest

cursorSummary :: Maybe RunSnapshot -> Text
cursorSummary = \case
  Nothing -> "?"
  Just snap -> case snap.rsStatus of
    MsCompleted -> "completed"
    MsFailed -> "failed"
    MsPaused _ -> "paused; last_host=" <> maybe "-" id snap.rsLastHost
    MsRunning -> "running; last_host=" <> maybe "-" id snap.rsLastHost
    MsDraining -> "draining; last_host=" <> maybe "-" id snap.rsLastHost

formatSpanTree :: [SpanNode] -> [Text]
formatSpanTree = concatMap (go 0)
  where
    go depth n =
      let pad = T.replicate depth "  "
          st = maybe "open" spanStatusText n.snStatus
          line =
            pad
              <> "└─ "
              <> n.snName
              <> " ["
              <> spanKindText n.snKind
              <> "] "
              <> st
       in line : concatMap (go (depth + 1)) n.snChildren

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
      )

formatSnapshot :: Maybe RunSnapshot -> Text
formatSnapshot = \case
  Nothing -> "no snapshot.json"
  Just snap ->
    let machineJson = maybe Aeson.Null machineToJson snap.rsMachine
        redacted = redactJson machineJson
     in TL.toStrict (TLE.decodeUtf8 (Aeson.encode redacted))
