-- | Append-only span writer / reader. O(1) per open/close — never rebuilds
-- the full history into RAM on each transition (spec §07 §8).
module Pml.Obs.Trace
  ( SpanState (..),
    newSpanState,
    openSpan,
    closeSpan,
    currentSpanId,
    setSpanStack,
    getSpanStack,
    appendEvent,
    readSpanRecords,
    SpanRecord (..),
    SpanNode (..),
    buildSpanForest,
    filterSpans,
  )
where

import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Pml.Obs.Redact (redactJson)
import Pml.Obs.Span
import Pml.Runtime.Snapshot (RunStore (..))
import System.Directory (doesFileExist)
import System.FilePath ((</>))

data SpanState = SpanState
  { ssCounter :: IORef Int,
    -- | Innermost span id at the head.
    ssStack :: IORef [SpanId]
  }

newSpanState :: IO SpanState
newSpanState = SpanState <$> newIORef 0 <*> newIORef []

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

-- | Open a span: append one jsonl line, push stack. O(1).
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
  appendSpanLine
    store
    ( object
        [ "op" .= String "open",
          "id" .= sid,
          "parent_id" .= parent,
          "name" .= name,
          "kind" .= spanKindText kind,
          "t_start" .= now,
          "attrs" .= redactJson attrs
        ]
    )
  pure sid

-- | Close a span: append one jsonl line, pop stack. O(1).
closeSpan ::
  RunStore ->
  SpanState ->
  SpanId ->
  SpanStatus ->
  Aeson.Value ->
  Maybe Int ->
  IO ()
closeSpan store st sid status attrs mSeq = do
  now <- isoNow
  modifyIORef' st.ssStack (pop sid)
  appendSpanLine
    store
    ( object
        [ "op" .= String "close",
          "id" .= sid,
          "t_end" .= now,
          "status" .= spanStatusText status,
          "attrs" .= redactJson attrs,
          "snapshot_seq" .= mSeq
        ]
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
        Aeson.encode $
          object
            [ "at" .= now,
              "span_id" .= sid,
              "level" .= level,
              "message" .= message,
              "fields" .= redactJson fields
            ]
  LBS.appendFile (store.storeRoot </> "events.jsonl") (line <> "\n")

appendSpanLine :: RunStore -> Aeson.Value -> IO ()
appendSpanLine store v =
  LBS.appendFile (store.storeRoot </> "spans.jsonl") (Aeson.encode v <> "\n")

isoNow :: IO Text
isoNow = do
  now <- getCurrentTime
  pure (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now))

-------------------------------------------------------------------------------
-- Read / tree (for show — not used on the hot step path)

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

readSpanRecords :: RunStore -> IO [SpanRecord]
readSpanRecords store = do
  let path = store.storeRoot </> "spans.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      bs <- LBS.readFile path
      let lines_ = filter (not . LBS.null) (LBS.split 10 bs)
      pure (mapMaybe decodeLine lines_)
  where
    decodeLine bs = case Aeson.eitherDecode bs of
      Left _ -> Nothing
      Right v -> case parseEither parseRecord v of
        Left _ -> Nothing
        Right r -> Just r

parseRecord :: Aeson.Value -> Parser SpanRecord
parseRecord = withObject "span" $ \o -> do
  op <- o .: "op"
  sid <- o .: "id"
  parent <- o .:? "parent_id"
  name <- o .:? "name"
  kindTxt <- o .:? "kind"
  tStart <- o .:? "t_start"
  tEnd <- o .:? "t_end"
  statusTxt <- o .:? "status"
  attrs <- o .:? "attrs"
  seqNo <- o .:? "snapshot_seq"
  pure
    SpanRecord
      { srOp = op,
        srId = sid,
        srParentId = parent,
        srName = name,
        srKind = kindTxt >>= parseSpanKind,
        srTStart = tStart,
        srTEnd = tEnd,
        srStatus = statusTxt >>= parseSpanStatus,
        srAttrs = maybe Null id attrs,
        srSnapshotSeq = seqNo
      }

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
                  snName = maybe "?" id o.srName,
                  snKind = maybe SkHost id o.srKind,
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
filterSpans Nothing = id
filterSpans (Just pref) =
  filter
    ( \r ->
        maybe False (pref `T.isPrefixOf`) r.srName
          || pref `T.isPrefixOf` r.srId
    )
