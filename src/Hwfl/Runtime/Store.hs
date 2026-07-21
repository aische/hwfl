-- | Run-store interface: list / read / write meta, snapshot, spans, events.
--
-- The FS backend keeps today’s layout under @.hwfl/runs/<id>/@. Callers use
-- 'RunStore' / 'RunStoreBackend' and must not assume paths. A future DB
-- backend can implement the same record.
module Hwfl.Runtime.Store
  ( -- * Handles
    RunStore,
    storeRunId,
    RunRef (..),
    runRef,

    -- * Filters / events
    SpanFilter (..),
    emptySpanFilter,
    StoreEvent (..),

    -- * Backend
    RunStoreBackend (..),
    fsRunStoreBackend,
    defaultRunStoreBackend,

    -- * Convenience (default FS backend)
    createRun,
    openRun,
    openRunDir,
    listRuns,
    writeMeta,
    readMeta,
    writeSnapshot,
    readSnapshot,
    appendSpan,
    appendEventValue,
    readSpans,
    readEventValues,
    persistTransition,

    -- * Compat aliases used by runtime / obs
    openRunStore,
    tryOpenRunStore,
    writeRunMeta,
    readRunMeta,
    writeRunSnapshot,
    readRunSnapshot,
    appendSpanLine,
    appendEventLine,
    readSpanRecords,
  )
where

import Control.Monad (filterM)
import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hwfl.Eval.Value (HostOpId, hostOpName)
import Hwfl.Eval.Value qualified as V
import Hwfl.Obs.Span
  ( SpanId,
    SpanRecord (..),
    filterSpansByPrefix,
    parseSpanKind,
    parseSpanStatus,
    spanKindText,
  )
import Hwfl.Runtime.Machine (Machine, MachineStatus)
import Hwfl.Runtime.Snapshot
  ( RunMeta (..),
    RunSnapshot (..),
    parseMetaValue,
    parseSnapshotValue,
    snapshotToJson,
    statusText,
    valueToJson,
  )
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    renamePath,
  )
import System.FilePath ((</>))

-- | Opaque per-run handle. FS backend stores a directory path internally.
data RunStore = RunStore
  { storeRoot :: FilePath,
    storeRunId :: Text,
    storeNotify :: StoreEvent -> IO ()
  }

instance Show RunStore where
  show s = "RunStore {storeRunId = " <> show s.storeRunId <> "}"

-- | Key for create/open. FS backend resolves @workspace/.hwfl/runs/<id>@.
data RunRef = RunRef
  { rrWorkspace :: FilePath,
    rrRunId :: Text
  }
  deriving stock (Eq, Show)

runRef :: FilePath -> Text -> RunRef
runRef = RunRef

data SpanFilter = SpanFilter
  { sfNamePrefix :: Maybe Text,
    sfKind :: Maybe Text,
    sfLimit :: Maybe Int
  }
  deriving stock (Eq, Show)

emptySpanFilter :: SpanFilter
emptySpanFilter = SpanFilter Nothing Nothing Nothing

data StoreEvent
  = SeSpan Aeson.Value
  | SeEvent Aeson.Value
  | SeStatusChanged Text
  | SeSnapshotSeq Int
  deriving stock (Eq, Show)

-- | Record-of-functions so lab / control-plane frontends can swap backends.
data RunStoreBackend = RunStoreBackend
  { rsCreate :: RunRef -> RunMeta -> IO RunStore,
    rsOpen :: RunRef -> IO (Maybe RunStore),
    rsWriteMeta :: RunStore -> RunMeta -> IO (),
    rsReadMeta :: RunStore -> IO (Maybe RunMeta),
    rsWriteSnapshot :: RunStore -> RunSnapshot -> IO (),
    rsReadSnapshot :: RunStore -> IO (Maybe RunSnapshot),
    rsAppendSpan :: RunStore -> Aeson.Value -> IO (),
    rsAppendEvent :: RunStore -> Aeson.Value -> IO (),
    rsListRuns :: FilePath -> IO [RunMeta],
    rsReadSpans :: RunStore -> SpanFilter -> IO [SpanRecord],
    rsReadEvents :: RunStore -> IO [Aeson.Value],
    rsNotify :: RunStore -> StoreEvent -> IO ()
  }

defaultRunStoreBackend :: RunStoreBackend
defaultRunStoreBackend = fsRunStoreBackend

-------------------------------------------------------------------------------
-- Convenience over the default FS backend

createRun :: RunRef -> RunMeta -> IO RunStore
createRun = rsCreate fsRunStoreBackend

openRun :: RunRef -> IO (Maybe RunStore)
openRun = rsOpen fsRunStoreBackend

listRuns :: FilePath -> IO [RunMeta]
listRuns = rsListRuns fsRunStoreBackend

writeMeta :: RunStore -> RunMeta -> IO ()
writeMeta = rsWriteMeta fsRunStoreBackend

readMeta :: RunStore -> IO (Maybe RunMeta)
readMeta = rsReadMeta fsRunStoreBackend

writeSnapshot :: RunStore -> RunSnapshot -> IO ()
writeSnapshot = rsWriteSnapshot fsRunStoreBackend

readSnapshot :: RunStore -> IO (Maybe RunSnapshot)
readSnapshot = rsReadSnapshot fsRunStoreBackend

appendSpan :: RunStore -> Aeson.Value -> IO ()
appendSpan = rsAppendSpan fsRunStoreBackend

appendEventValue :: RunStore -> Aeson.Value -> IO ()
appendEventValue = rsAppendEvent fsRunStoreBackend

readSpans :: RunStore -> SpanFilter -> IO [SpanRecord]
readSpans = rsReadSpans fsRunStoreBackend

readEventValues :: RunStore -> IO [Aeson.Value]
readEventValues = rsReadEvents fsRunStoreBackend

-- | Open (create) a run directory at an absolute path — tests / placeholders.
openRunDir :: FilePath -> Text -> IO RunStore
openRunDir root runId = do
  createDirectoryIfMissing True root
  pure (mkHandle root runId (const (pure ())))

-------------------------------------------------------------------------------
-- Compat names (runtime / obs call sites)

openRunStore :: FilePath -> Text -> IO RunStore
openRunStore workspace runId = do
  let root = runsRoot workspace </> T.unpack runId
  openRunDir root runId

tryOpenRunStore :: FilePath -> Text -> IO (Maybe RunStore)
tryOpenRunStore workspace runId = openRun (runRef workspace runId)

writeRunMeta :: RunStore -> RunMeta -> IO ()
writeRunMeta = writeMeta

readRunMeta :: RunStore -> IO (Maybe RunMeta)
readRunMeta = readMeta

writeRunSnapshot :: RunStore -> RunSnapshot -> IO ()
writeRunSnapshot = writeSnapshot

readRunSnapshot :: RunStore -> IO (Maybe RunSnapshot)
readRunSnapshot = readSnapshot

appendSpanLine :: RunStore -> Aeson.Value -> IO ()
appendSpanLine = appendSpan

appendEventLine :: RunStore -> Aeson.Value -> IO ()
appendEventLine = appendEventValue

readSpanRecords :: RunStore -> IO [SpanRecord]
readSpanRecords store = readSpans store emptySpanFilter

persistTransition ::
  RunStore ->
  IORef Int ->
  Text ->
  Maybe HostOpId ->
  Maybe V.Value ->
  MachineStatus ->
  Maybe Machine ->
  [Text] ->
  Int ->
  IO ()
persistTransition store seqRef projectHash mHost mVal status mMachine spanStack spanCounter = do
  modifyIORef' seqRef (+ 1)
  seqNo <- readIORef seqRef
  now <- getCurrentTime
  let at = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      snap =
        RunSnapshot
          { rsFormat = 1,
            rsRunId = store.storeRunId,
            rsSeq = seqNo,
            rsStatus = status,
            rsProjectHash = projectHash,
            rsLastHost = fmap hostOpName mHost,
            rsLastResult = fmap valueToJson mVal,
            rsAt = at,
            rsMachine = mMachine,
            rsSpanStack = spanStack,
            rsSpanCounter = spanCounter
          }
  writeRunSnapshot store snap

-------------------------------------------------------------------------------
-- FS backend

fsRunStoreBackend :: RunStoreBackend
fsRunStoreBackend =
  RunStoreBackend
    { rsCreate = fsCreate,
      rsOpen = fsOpen,
      rsWriteMeta = fsWriteMeta,
      rsReadMeta = fsReadMeta,
      rsWriteSnapshot = fsWriteSnapshot,
      rsReadSnapshot = fsReadSnapshot,
      rsAppendSpan = fsAppendSpan,
      rsAppendEvent = fsAppendEvent,
      rsListRuns = fsListRuns,
      rsReadSpans = fsReadSpans,
      rsReadEvents = fsReadEvents,
      rsNotify = \store ev -> store.storeNotify ev
    }

mkHandle :: FilePath -> Text -> (StoreEvent -> IO ()) -> RunStore
mkHandle root runId notify =
  RunStore
    { storeRoot = root,
      storeRunId = runId,
      storeNotify = notify
    }

runsRoot :: FilePath -> FilePath
runsRoot workspace = workspace </> ".hwfl" </> "runs"

fsCreate :: RunRef -> RunMeta -> IO RunStore
fsCreate ref meta = do
  let root = runsRoot ref.rrWorkspace </> T.unpack ref.rrRunId
  createDirectoryIfMissing True root
  let store = mkHandle root ref.rrRunId (const (pure ()))
  fsWriteMeta store meta
  pure store

fsOpen :: RunRef -> IO (Maybe RunStore)
fsOpen ref = do
  let root = runsRoot ref.rrWorkspace </> T.unpack ref.rrRunId
  exists <- doesDirectoryExist root
  if not exists
    then pure Nothing
    else do
      let store = mkHandle root ref.rrRunId (const (pure ()))
      mMeta <- fsReadMeta store
      mSnap <- fsReadSnapshot store
      pure $ case (mMeta, mSnap) of
        (Nothing, Nothing) -> Nothing
        _ -> Just store

fsWriteMeta :: RunStore -> RunMeta -> IO ()
fsWriteMeta store meta = do
  atomicEncodeFile
    (store.storeRoot </> "meta.json")
    ( object
        [ "run_id" .= meta.rmRunId,
          "project_hash" .= meta.rmProjectHash,
          "entry" .= meta.rmEntry,
          "started_at" .= meta.rmStartedAt,
          "status" .= meta.rmStatus
        ]
    )
  store.storeNotify (SeStatusChanged meta.rmStatus)

fsReadMeta :: RunStore -> IO (Maybe RunMeta)
fsReadMeta store = do
  let path = store.storeRoot </> "meta.json"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      eresult <- Aeson.eitherDecodeFileStrict path
      pure $ case eresult of
        Left _ -> Nothing
        Right v -> case parseEither parseMetaValue v of
          Left _ -> Nothing
          Right m -> Just m

fsWriteSnapshot :: RunStore -> RunSnapshot -> IO ()
fsWriteSnapshot store snap = do
  -- Snapshot first (atomic replace), then append the transition line.
  -- Progress is defined by snapshot; a crash after rename but before
  -- append leaves transitions lagging, which is recoverable.
  atomicEncodeFile (store.storeRoot </> "snapshot.json") (snapshotToJson snap)
  let line =
        Aeson.encode $
          object
            [ "seq" .= snap.rsSeq,
              "host" .= snap.rsLastHost,
              "status" .= statusText snap.rsStatus,
              "at" .= snap.rsAt
            ]
  LBS.appendFile (store.storeRoot </> "transitions.jsonl") (line <> "\n")
  store.storeNotify (SeSnapshotSeq snap.rsSeq)

-- | Write JSON via temp file + rename so a crash mid-encode cannot
-- truncate an existing durable file. Same-directory rename is atomic
-- on POSIX when replacing a regular file.
atomicEncodeFile :: FilePath -> Aeson.Value -> IO ()
atomicEncodeFile path value = do
  let tmp = path <> ".tmp"
  Aeson.encodeFile tmp value
  renamePath tmp path

fsReadSnapshot :: RunStore -> IO (Maybe RunSnapshot)
fsReadSnapshot store = do
  let path = store.storeRoot </> "snapshot.json"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      eresult <- Aeson.eitherDecodeFileStrict path
      pure $ case eresult of
        Left _ -> Nothing
        Right v -> case parseEither parseSnapshotValue v of
          Left _ -> Nothing
          Right s -> Just s

fsAppendSpan :: RunStore -> Aeson.Value -> IO ()
fsAppendSpan store v = do
  LBS.appendFile (store.storeRoot </> "spans.jsonl") (Aeson.encode v <> "\n")
  store.storeNotify (SeSpan v)

fsAppendEvent :: RunStore -> Aeson.Value -> IO ()
fsAppendEvent store v = do
  LBS.appendFile (store.storeRoot </> "events.jsonl") (Aeson.encode v <> "\n")
  store.storeNotify (SeEvent v)

fsListRuns :: FilePath -> IO [RunMeta]
fsListRuns workspace = do
  let root = runsRoot workspace
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      names <- listDirectory root
      dirs <- filterM (\n -> doesDirectoryExist (root </> n)) names
      metas <- mapM (readMetaForDir root) dirs
      pure (catMaybes metas)
  where
    readMetaForDir root name = do
      let store = mkHandle (root </> name) (T.pack name) (const (pure ()))
      fsReadMeta store

fsReadSpans :: RunStore -> SpanFilter -> IO [SpanRecord]
fsReadSpans store filt = do
  records <- readSpanRecordsAt store.storeRoot
  pure (applySpanFilter filt records)

fsReadEvents :: RunStore -> IO [Aeson.Value]
fsReadEvents store = do
  let path = store.storeRoot </> "events.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      bs <- LBS.readFile path
      let lines_ = filter (not . LBS.null) (LBS.split 10 bs)
      pure (mapMaybe decodeValue lines_)
  where
    decodeValue bs = case Aeson.eitherDecode bs of
      Left _ -> Nothing
      Right v -> Just v

applySpanFilter :: SpanFilter -> [SpanRecord] -> [SpanRecord]
applySpanFilter filt =
  maybeLimit filt.sfLimit
    . filterKind filt.sfKind
    . filterSpansByPrefix filt.sfNamePrefix
  where
    filterKind Nothing = id
    filterKind (Just k) =
      filter
        ( \r ->
            case r.srKind of
              Just kind -> k == spanKindText kind || k `T.isPrefixOf` spanKindText kind
              Nothing -> k `T.isPrefixOf` r.srId
        )
    maybeLimit Nothing xs = xs
    maybeLimit (Just n) xs = take n xs

-------------------------------------------------------------------------------
-- Span jsonl decode (cold path)

readSpanRecordsAt :: FilePath -> IO [SpanRecord]
readSpanRecordsAt root = do
  let path = root </> "spans.jsonl"
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
      Right v -> case parseEither parseSpanRecord v of
        Left _ -> Nothing
        Right r -> Just r

parseSpanRecord :: Aeson.Value -> Parser SpanRecord
parseSpanRecord = withObject "span" $ \o -> do
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
        srId = sid :: SpanId,
        srParentId = parent,
        srName = name,
        srKind = kindTxt >>= parseSpanKind,
        srTStart = tStart,
        srTEnd = tEnd,
        srStatus = statusTxt >>= parseSpanStatus,
        srAttrs = fromMaybe Null attrs,
        srSnapshotSeq = seqNo
      }
