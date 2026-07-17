-- | Append-only span writer / reader. O(1) per open/close — never rebuilds
-- the full history into RAM on each transition (spec §07 §8).
module Hwfl.Obs.Trace
  ( SpanState (..),
    newSpanState,
    newSpanStateWith,
    openSpan,
    closeSpan,
    currentSpanId,
    setSpanStack,
    getSpanStack,
    appendEvent,
    debugLog,
    runCostPrefix,
    readSpanRecords,
    SpanRecord (..),
    SpanNode (..),
    buildSpanForest,
    filterSpans,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hwfl.Llm.Pricing (attrsCostMicros, formatCostUsd)
import Hwfl.Obs.Observer
  ( ObsEvent (..),
    Observer,
    SpanCloseInfo (..),
    SpanOpenInfo (..),
    noopObserver,
  )
import Hwfl.Obs.Redact (redactJson)
import Hwfl.Obs.Span
  ( SpanId,
    SpanKind (..),
    SpanRecord (..),
    SpanStatus (..),
    filterSpansByPrefix,
    spanKindText,
    spanStatusText,
  )
import Hwfl.Runtime.Store
  ( RunStore,
    appendEventLine,
    appendSpanLine,
    readSpanRecords,
  )

data SpanState = SpanState
  { ssCounter :: IORef Int,
    -- | Innermost span id at the head.
    ssStack :: IORef [SpanId],
    -- | Running LLM cost (microdollars) for @--debug@ / @--cost@ ledger prefix.
    ssRunCostMicros :: IORef Int,
    -- | Live observer (span open/close, progress). Default: noop.
    ssObserver :: Observer
  }

newSpanState :: IO SpanState
newSpanState = newSpanStateWith noopObserver

newSpanStateWith :: Observer -> IO SpanState
newSpanStateWith obs =
  SpanState <$> newIORef 0 <*> newIORef [] <*> newIORef 0 <*> pure obs

getSpanStack :: SpanState -> IO [SpanId]
getSpanStack st = readIORef st.ssStack

setSpanStack :: SpanState -> [SpanId] -> IO ()
setSpanStack st = writeIORef st.ssStack

currentSpanId :: SpanState -> IO (Maybe SpanId)
currentSpanId st = do
  stack <- readIORef st.ssStack
  pure $ case stack of
    (x : _) -> Just x
    [] -> Nothing

-- | Progressive / free-form debug line (LLM deltas). Includes cost prefix.
debugLog :: SpanState -> Text -> IO ()
debugLog st msg = do
  prefix <- runCostPrefix st
  st.ssObserver (ObsProgress (prefix <> msg))

runCostPrefix :: SpanState -> IO Text
runCostPrefix st = do
  micros <- readIORef st.ssRunCostMicros
  pure (formatCostUsd micros <> " │ ")

chargeCostFromAttrs :: SpanState -> Aeson.Value -> IO ()
chargeCostFromAttrs st attrs =
  case attrsCostMicros attrs of
    Nothing -> pure ()
    Just micros ->
      modifyIORef' st.ssRunCostMicros (+ micros)

-- | Open a span: append one jsonl line, push stack, notify observer. O(1).
openSpan ::
  RunStore ->
  SpanState ->
  Text ->
  SpanKind ->
  Aeson.Value ->
  IO SpanId
openSpan store st name kind attrs = do
  modifyIORef' st.ssCounter (+ 1)
  n <- readIORef st.ssCounter
  let sid = "span-" <> T.pack (show n)
  parent <- currentSpanId st
  modifyIORef' st.ssStack (sid :)
  now <- isoNow
  let redacted = redactJson attrs
  appendSpanLine
    store
    ( object
        [ "op" .= String "open",
          "id" .= sid,
          "parent_id" .= parent,
          "name" .= name,
          "kind" .= spanKindText kind,
          "t_start" .= now,
          "attrs" .= redacted
        ]
    )
  prefix <- runCostPrefix st
  st.ssObserver
    ( ObsSpanOpen
        SpanOpenInfo
          { soId = sid,
            soParentId = parent,
            soName = name,
            soKind = kind,
            soAttrs = redacted,
            soCostPrefix = prefix
          }
    )
  pure sid

-- | Close a span: append one jsonl line, pop stack, notify observer. O(1).
closeSpan ::
  RunStore ->
  SpanState ->
  SpanId ->
  SpanStatus ->
  Aeson.Value ->
  Maybe Int ->
  IO ()
closeSpan store st sid status attrs mSeq = do
  chargeCostFromAttrs st attrs
  now <- isoNow
  modifyIORef' st.ssStack (pop sid)
  let redacted = redactJson attrs
  appendSpanLine
    store
    ( object
        [ "op" .= String "close",
          "id" .= sid,
          "t_end" .= now,
          "status" .= spanStatusText status,
          "attrs" .= redacted,
          "snapshot_seq" .= mSeq
        ]
    )
  prefix <- runCostPrefix st
  st.ssObserver
    ( ObsSpanClose
        SpanCloseInfo
          { scId = sid,
            scStatus = status,
            scAttrs = redacted,
            scSnapshotSeq = mSeq,
            scCostPrefix = prefix
          }
    )
  where
    pop target = \case
      (x : xs) | x == target -> xs
      xs -> xs

appendEvent :: RunStore -> SpanState -> Text -> Text -> Aeson.Value -> IO ()
appendEvent store st level message fields = do
  sid <- currentSpanId st
  now <- isoNow
  let line =
        object
          [ "at" .= now,
            "span_id" .= sid,
            "level" .= level,
            "message" .= message,
            "fields" .= redactJson fields
          ]
  appendEventLine store line

isoNow :: IO Text
isoNow = do
  T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime

-------------------------------------------------------------------------------
-- Read / tree (for show — not used on the hot step path)

data SpanNode = SpanNode
  { snId :: SpanId,
    snName :: Text,
    snKind :: SpanKind,
    snTStart :: Maybe Text,
    snTEnd :: Maybe Text,
    snStatus :: Maybe SpanStatus,
    snAttrs :: Aeson.Value,
    snChildren :: [SpanNode]
  }
  deriving stock (Eq, Show)

-- | Merge open/close lines into a forest by parent_id. Used only by show.
buildSpanForest :: [SpanRecord] -> [SpanNode]
buildSpanForest records =
  let opens = [r | r <- records, r.srOp == "open"]
      closeMap = Map.fromList [(r.srId, r) | r <- records, r.srOp == "close"]
      parentOf = Map.fromList [(o.srId, o.srParentId) | o <- opens]
      nodeMap =
        Map.fromList
          [ ( o.srId,
              SpanNode
                { snId = o.srId,
                  snName = fromMaybe "?" o.srName,
                  snKind = fromMaybe SkHost o.srKind,
                  snTStart = o.srTStart,
                  snTEnd = Map.lookup o.srId closeMap >>= (.srTEnd),
                  snStatus = Map.lookup o.srId closeMap >>= (.srStatus),
                  snAttrs = mergeAttrs o.srAttrs (maybe Null (.srAttrs) (Map.lookup o.srId closeMap)),
                  snChildren = []
                }
            )
            | o <- opens
          ]
      childrenOf pid =
        [ cid
          | (cid, mp) <- Map.toList parentOf,
            mp == Just pid
        ]
      go n =
        n
          { snChildren =
              [ go c
                | cid <- childrenOf n.snId,
                  Just c <- [Map.lookup cid nodeMap]
              ]
          }
   in [ go n
        | o <- opens,
          case Map.lookup o.srId parentOf of
            Just Nothing -> True
            Just (Just _) -> False
            Nothing -> True,
          Just n <- [Map.lookup o.srId nodeMap]
      ]
  where
    mergeAttrs a Null = a
    mergeAttrs Null b = b
    mergeAttrs (Object a) (Object b) = Object (KM.union b a)
    mergeAttrs _ b = b

filterSpans :: Maybe Text -> [SpanRecord] -> [SpanRecord]
filterSpans = filterSpansByPrefix
