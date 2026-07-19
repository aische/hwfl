-- | Live run observer: structured span / pause / progress callbacks.
--
-- CLI @--debug@ is one frontend ('stderrDebugObserver'). A control-plane
-- WebSocket / SSE layer maps onto the same hook without scraping the FS.
module Hwfl.Obs.Observer
  ( Observer,
    ObsEvent (..),
    SpanOpenInfo (..),
    SpanCloseInfo (..),
    PauseInfo (..),
    FinishedInfo (..),
    noopObserver,
    stderrDebugObserver,
    mappendObserver,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Obs.Span
  ( SpanId,
    SpanKind,
    SpanStatus,
    compactAttrs,
    spanKindText,
    spanStatusText,
  )
import System.IO (hPutStrLn, stderr)

-- | Callback invoked on the hot path for live observability.
type Observer = ObsEvent -> IO ()

data ObsEvent
  = -- | Span opened (after durable append).
    ObsSpanOpen SpanOpenInfo
  | -- | Span closed (after durable append).
    ObsSpanClose SpanCloseInfo
  | -- | Coalesced progressive / host debug line (e.g. LLM deltas).
    ObsProgress Text
  | -- | Machine paused (step gate or awaiting human confirm).
    ObsPaused PauseInfo
  | -- | Terminal status (completed / failed).
    ObsFinished FinishedInfo
  deriving stock (Eq, Show)

data SpanOpenInfo = SpanOpenInfo
  { soId :: SpanId,
    soParentId :: Maybe SpanId,
    soName :: Text,
    soKind :: SpanKind,
    soAttrs :: Aeson.Value,
    -- | Running LLM cost prefix for CLI formatting (may be empty).
    soCostPrefix :: Text
  }
  deriving stock (Eq, Show)

data SpanCloseInfo = SpanCloseInfo
  { scId :: SpanId,
    scStatus :: SpanStatus,
    scAttrs :: Aeson.Value,
    scSnapshotSeq :: Maybe Int,
    scCostPrefix :: Text
  }
  deriving stock (Eq, Show)

data PauseInfo = PauseInfo
  { piRunId :: Text,
    -- | @paused@ | @awaiting_confirm@ | @awaiting_choice@
    piStatus :: Text,
    piMessage :: Text,
    piConfirmTitle :: Maybe Text,
    piConfirmDetail :: Maybe Text,
    -- | Present when status is @awaiting_choice@.
    piChoiceOptions :: Maybe [Text]
  }
  deriving stock (Eq, Show)

data FinishedInfo = FinishedInfo
  { fiRunId :: Text,
    -- | @completed@ | @failed@
    fiStatus :: Text,
    fiMessage :: Maybe Text
  }
  deriving stock (Eq, Show)

noopObserver :: Observer
noopObserver = const (pure ())

-- | Compose two observers (both always run).
mappendObserver :: Observer -> Observer -> Observer
mappendObserver a b ev = a ev >> b ev

-- | Format live events the way CLI @--debug@ historically printed to stderr.
stderrDebugObserver :: Observer
stderrDebugObserver = \case
  ObsSpanOpen i ->
    hPutStrLn
      stderr
      ( T.unpack $
          i.soCostPrefix
            <> "span open  "
            <> i.soId
            <> "  "
            <> i.soName
            <> " ["
            <> spanKindText i.soKind
            <> "] "
            <> compactAttrs i.soAttrs
      )
  ObsSpanClose i ->
    hPutStrLn
      stderr
      ( T.unpack $
          i.scCostPrefix
            <> "span close "
            <> i.scId
            <> "  "
            <> spanStatusText i.scStatus
            <> " "
            <> compactAttrs i.scAttrs
      )
  ObsProgress msg -> hPutStrLn stderr (T.unpack msg)
  ObsPaused i ->
    hPutStrLn
      stderr
      ( T.unpack $
          "hwfl: paused run_id="
            <> i.piRunId
            <> " status="
            <> i.piStatus
            <> " — "
            <> i.piMessage
      )
  ObsFinished i ->
    hPutStrLn
      stderr
      ( T.unpack $
          "hwfl: "
            <> i.fiStatus
            <> " run_id="
            <> i.fiRunId
            <> maybe "" (" — " <>) i.fiMessage
      )
