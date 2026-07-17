-- | Coalescing sink for progressive LLM deltas on an open span (spec §07 §9).
-- Partials go to @events.jsonl@ (and optional @--debug@ echo); they are not
-- control-flow truth and do not mutate @spans.jsonl@ mid-call.
module Hwfl.Obs.Stream
  ( StreamSink (..),
    newStreamSink,
  )
where

import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Hwfl.Llm.Types (StreamDelta (..), ToolCall (..))
import Hwfl.Obs.Trace (SpanState, appendEvent, debugLog)
import Hwfl.Runtime.Snapshot (RunStore)

-- | Character budget before a forced text flush (avoids flooding events.jsonl).
charBudget :: Int
charBudget = 64

-- | Time budget (seconds) before a forced text flush.
timeBudgetSec :: Double
timeBudgetSec = 0.1

-- | Live progressive sink bound to the current open LLM / agent_round span.
data StreamSink = StreamSink
  { -- | Feed one provider delta (coalesces text; tool calls flush immediately).
    ssOnChunk :: StreamDelta -> IO (),
    -- | Flush any buffered text (call before span close / after provider returns).
    ssFlush :: IO ()
  }

data BufKind = BufText | BufReasoning
  deriving stock (Eq)

data Buffer = Buffer
  { bufKind :: BufKind,
    bufText :: Text
  }

newStreamSink :: RunStore -> SpanState -> IO StreamSink
newStreamSink store st = do
  bufRef <- newIORef (Nothing :: Maybe Buffer)
  lastFlushRef <- newIORef =<< getCurrentTime
  let flush = flushBuffer store st bufRef lastFlushRef
      onChunk = handleDelta store st bufRef lastFlushRef flush
  pure StreamSink {ssOnChunk = onChunk, ssFlush = flush}

handleDelta ::
  RunStore ->
  SpanState ->
  IORef (Maybe Buffer) ->
  IORef UTCTime ->
  IO () ->
  StreamDelta ->
  IO ()
handleDelta store st bufRef lastFlushRef flush = \case
  DeltaText t
    | T.null t -> pure ()
    | otherwise -> appendText store st bufRef lastFlushRef BufText t
  DeltaReasoning t
    | T.null t -> pure ()
    | otherwise -> appendText store st bufRef lastFlushRef BufReasoning t
  DeltaToolCall tc -> do
    flush
    emitEvent store st (toolCallFields tc)
    debugLog
      st
      ( "llm Δ     tool_call name="
          <> tc.tcName
          <> " id="
          <> tc.tcId
      )

appendText ::
  RunStore ->
  SpanState ->
  IORef (Maybe Buffer) ->
  IORef UTCTime ->
  BufKind ->
  Text ->
  IO ()
appendText store st bufRef lastFlushRef kind chunk = do
  cur <- readIORef bufRef
  case cur of
    Just b | b.bufKind /= kind -> do
      flushBuffer store st bufRef lastFlushRef
      writeIORef bufRef (Just Buffer {bufKind = kind, bufText = chunk})
      maybeFlush store st bufRef lastFlushRef
    Just b -> do
      let next = b.bufText <> chunk
      writeIORef bufRef (Just b {bufText = next})
      maybeFlush store st bufRef lastFlushRef
    Nothing -> do
      writeIORef bufRef (Just Buffer {bufKind = kind, bufText = chunk})
      maybeFlush store st bufRef lastFlushRef

maybeFlush ::
  RunStore ->
  SpanState ->
  IORef (Maybe Buffer) ->
  IORef UTCTime ->
  IO ()
maybeFlush store st bufRef lastFlushRef = do
  mbuf <- readIORef bufRef
  case mbuf of
    Nothing -> pure ()
    Just b -> do
      now <- getCurrentTime
      last_ <- readIORef lastFlushRef
      let elapsed = realToFrac (diffUTCTime now last_) :: Double
          overChars = T.length b.bufText >= charBudget
          overTime = elapsed >= timeBudgetSec && not (T.null b.bufText)
      when (overChars || overTime) $
        flushBuffer store st bufRef lastFlushRef

flushBuffer ::
  RunStore ->
  SpanState ->
  IORef (Maybe Buffer) ->
  IORef UTCTime ->
  IO ()
flushBuffer store st bufRef lastFlushRef = do
  mbuf <- readIORef bufRef
  case mbuf of
    Nothing -> pure ()
    Just b
      | T.null b.bufText -> writeIORef bufRef Nothing
      | otherwise -> do
          writeIORef bufRef Nothing
          writeIORef lastFlushRef =<< getCurrentTime
          let (kindKey, label) = case b.bufKind of
                BufText -> ("text" :: Text, "text")
                BufReasoning -> ("reasoning", "reasoning")
          emitEvent
            store
            st
            (object ["kind" .= kindKey, "text" .= b.bufText])
          debugLog
            st
            ( "llm Δ     "
                <> label
                <> "="
                <> compactText b.bufText
            )

emitEvent :: RunStore -> SpanState -> Aeson.Value -> IO ()
emitEvent store st fields =
  appendEvent store st "debug" "llm.delta" fields

toolCallFields :: ToolCall -> Aeson.Value
toolCallFields tc =
  object
    [ "kind" .= ("tool_call" :: Text),
      "id" .= tc.tcId,
      "name" .= tc.tcName,
      "arguments" .= tc.tcArguments
    ]

compactText :: Text -> Text
compactText t
  | T.length t <= 48 = t
  | otherwise = T.take 45 t <> "…"
