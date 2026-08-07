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
    runStoreHandle,
    detachedRunStore,

    -- * Run ids
    RunIdError (..),
    validateRunId,
    renderRunIdError,
    maxRunIdLength,
    RunStoreError (..),
    renderRunStoreError,

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
    writeRunMeta,
    readRunMeta,
    writeRunSnapshot,
    readRunSnapshot,
    appendSpanLine,
    appendEventLine,
    readSpanRecords,
  )
where

import Control.Exception (throwIO, try)
import Control.Monad (filterM)
import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
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
  ( createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    renamePath,
  )
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError)

-- | Opaque per-run handle. 'Nothing' is a detached handle (see
-- 'detachedRunStore'): it is backed by no directory, so writes are dropped
-- and reads are empty.
data RunStore = RunStore
  { storeRoot :: Maybe FilePath,
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

-------------------------------------------------------------------------------
-- Run ids

-- | Why a run id cannot be used as a store key.
--
-- The FS backend joins the run id into @.hwfl/runs/<id>@, and the library
-- API takes run ids from callers (control plane, workflow code via
-- @meta.read_*@), so ids are untrusted input and must denote a single path
-- component.
data RunIdError
  = RunIdEmpty
  | RunIdTooLong Int
  | -- | Leading @.@ — also rules out @.@ and @..@.
    RunIdLeadingDot
  | RunIdBadChar Char
  deriving stock (Eq, Show)

renderRunIdError :: RunIdError -> Text
renderRunIdError = \case
  RunIdEmpty -> "run id must not be empty"
  RunIdTooLong n ->
    "run id is "
      <> T.pack (show n)
      <> " characters; maximum is "
      <> T.pack (show maxRunIdLength)
  RunIdLeadingDot -> "run id must not start with '.'"
  RunIdBadChar c ->
    "run id contains invalid character "
      <> T.pack (show c)
      <> "; allowed: A-Z a-z 0-9 '.' '_' '-'"

maxRunIdLength :: Int
maxRunIdLength = 128

-- | Accept a run id only if it is a single, portable path component.
validateRunId :: Text -> Either RunIdError Text
validateRunId rid
  | T.null rid = Left RunIdEmpty
  | T.length rid > maxRunIdLength = Left (RunIdTooLong (T.length rid))
  | "." `T.isPrefixOf` rid = Left RunIdLeadingDot
  | otherwise = case T.find (not . isRunIdChar) rid of
      Just c -> Left (RunIdBadChar c)
      Nothing -> Right rid
  where
    isRunIdChar c =
      isAsciiUpper c || isAsciiLower c || isDigit c || c == '.' || c == '_' || c == '-'

-- | Failures of the create/open path that are the caller's fault.
data RunStoreError
  = RseRunId RunIdError
  | -- | Starting a run into an id that already has a run directory. Reusing
    -- an id would merge two runs (old snapshot / spans survive while meta is
    -- replaced and the sequence restarts); continue an existing run with
    -- resume / step instead.
    RseAlreadyExists Text
  deriving stock (Eq, Show)

renderRunStoreError :: RunStoreError -> Text
renderRunStoreError = \case
  RseRunId e -> renderRunIdError e
  RseAlreadyExists rid -> "run id already exists: " <> rid

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
  { -- | Create a *new* run; fails on an invalid or already-used run id.
    rsCreate :: RunRef -> RunMeta -> IO (Either RunStoreError RunStore),
    -- | Open an existing run; 'Nothing' when the id is invalid or unknown.
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

createRun :: RunRef -> RunMeta -> IO (Either RunStoreError RunStore)
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
-- The run id is not part of the path here, so it is not validated.
openRunDir :: FilePath -> Text -> IO RunStore
openRunDir root runId = do
  createDirectoryIfMissing True root
  pure (mkHandle (Just root) runId (const (pure ())))

-- | Pure handle for a run that may not exist. Creates nothing; an invalid
-- run id yields a detached handle. Failure paths use this to report an
-- outcome for a run they could not open, without materialising a directory.
runStoreHandle :: RunRef -> RunStore
runStoreHandle ref = case runDirFor ref.rrWorkspace ref.rrRunId of
  Left _ -> detachedRunStore ref.rrRunId
  Right root -> mkHandle (Just root) ref.rrRunId (const (pure ()))

-- | Handle backed by no directory: writes are dropped, reads are empty.
detachedRunStore :: Text -> RunStore
detachedRunStore runId = mkHandle Nothing runId (const (pure ()))

-------------------------------------------------------------------------------
-- Compat names (runtime / obs call sites)

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

mkHandle :: Maybe FilePath -> Text -> (StoreEvent -> IO ()) -> RunStore
mkHandle root runId notify =
  RunStore
    { storeRoot = root,
      storeRunId = runId,
      storeNotify = notify
    }

-- | Run the action against the store's directory; detached handles yield the
-- fallback without touching the filesystem.
withStoreRoot :: RunStore -> a -> (FilePath -> IO a) -> IO a
withStoreRoot store fallback act = case store.storeRoot of
  Nothing -> pure fallback
  Just root -> act root

runsRoot :: FilePath -> FilePath
runsRoot workspace = workspace </> ".hwfl" </> "runs"

-- | Run directory for a validated id. The id must be a single path
-- component: an id like @../../x@ would otherwise read and write outside the
-- workspace.
runDirFor :: FilePath -> Text -> Either RunIdError FilePath
runDirFor workspace rid = (\r -> runsRoot workspace </> T.unpack r) <$> validateRunId rid

fsCreate :: RunRef -> RunMeta -> IO (Either RunStoreError RunStore)
fsCreate ref meta = case runDirFor ref.rrWorkspace ref.rrRunId of
  Left e -> pure (Left (RseRunId e))
  Right root -> do
    createDirectoryIfMissing True (runsRoot ref.rrWorkspace)
    -- createDirectory (not …IfMissing) so an id already in use is rejected
    -- without a check/create race.
    created <- try (createDirectory root)
    case created of
      Left err
        | isAlreadyExistsError err -> pure (Left (RseAlreadyExists ref.rrRunId))
        | otherwise -> throwIO err
      Right () -> do
        let store = mkHandle (Just root) ref.rrRunId (const (pure ()))
        fsWriteMeta store meta
        pure (Right store)

fsOpen :: RunRef -> IO (Maybe RunStore)
fsOpen ref = case runDirFor ref.rrWorkspace ref.rrRunId of
  Left _ -> pure Nothing
  Right root -> do
    exists <- doesDirectoryExist root
    if not exists
      then pure Nothing
      else do
        let store = mkHandle (Just root) ref.rrRunId (const (pure ()))
        mMeta <- fsReadMeta store
        mSnap <- fsReadSnapshot store
        pure $ case (mMeta, mSnap) of
          (Nothing, Nothing) -> Nothing
          _ -> Just store

fsWriteMeta :: RunStore -> RunMeta -> IO ()
fsWriteMeta store meta = withStoreRoot store () $ \root -> do
  atomicEncodeFile
    (root </> "meta.json")
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
fsReadMeta store = withStoreRoot store Nothing $ \root -> do
  let path = root </> "meta.json"
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
fsWriteSnapshot store snap = withStoreRoot store () $ \root -> do
  -- Snapshot first (atomic replace), then append the transition line.
  -- Progress is defined by snapshot; a crash after rename but before
  -- append leaves transitions lagging, which is recoverable.
  atomicEncodeFile (root </> "snapshot.json") (snapshotToJson snap)
  let line =
        Aeson.encode $
          object
            [ "seq" .= snap.rsSeq,
              "host" .= snap.rsLastHost,
              "status" .= statusText snap.rsStatus,
              "at" .= snap.rsAt
            ]
  LBS.appendFile (root </> "transitions.jsonl") (line <> "\n")
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
fsReadSnapshot store = withStoreRoot store Nothing $ \root -> do
  let path = root </> "snapshot.json"
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
fsAppendSpan store v = withStoreRoot store () $ \root -> do
  LBS.appendFile (root </> "spans.jsonl") (Aeson.encode v <> "\n")
  store.storeNotify (SeSpan v)

fsAppendEvent :: RunStore -> Aeson.Value -> IO ()
fsAppendEvent store v = withStoreRoot store () $ \root -> do
  LBS.appendFile (root </> "events.jsonl") (Aeson.encode v <> "\n")
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
      let store = mkHandle (Just (root </> name)) (T.pack name) (const (pure ()))
      fsReadMeta store

fsReadSpans :: RunStore -> SpanFilter -> IO [SpanRecord]
fsReadSpans store filt = withStoreRoot store [] $ \root -> do
  records <- readSpanRecordsAt root
  pure (applySpanFilter filt records)

fsReadEvents :: RunStore -> IO [Aeson.Value]
fsReadEvents store = withStoreRoot store [] $ \root -> do
  let path = root </> "events.jsonl"
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
