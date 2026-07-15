-- | Host-boundary snapshots (resume points). Full kont/@machine_json@ for
-- @pml resume@ is M5; M4 writes format-1 boundary records after each host op.
module Pml.Runtime.Snapshot
  ( RunStatus (..),
    BoundarySnapshot (..),
    RunStore (..),
    openRunStore,
    writeBoundarySnapshot,
    readBoundarySnapshot,
    valueToJson,
    mkBoundary,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Eval.Value (HostOpId, hostOpName)
import Pml.Eval.Value qualified as V
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

data RunStatus
  = StatusRunning
  | StatusCompleted
  | StatusFailed
  deriving stock (Eq, Show)

instance ToJSON RunStatus where
  toJSON = \case
    StatusRunning -> String "running"
    StatusCompleted -> String "completed"
    StatusFailed -> String "failed"

instance FromJSON RunStatus where
  parseJSON = Aeson.withText "RunStatus" $ \case
    "running" -> pure StatusRunning
    "completed" -> pure StatusCompleted
    "failed" -> pure StatusFailed
    other -> fail ("unknown status: " <> T.unpack other)

-- | Snapshot after a completed host transition (spec §06 §4 layout fields).
data BoundarySnapshot = BoundarySnapshot
  { bsFormat :: Int,
    bsRunId :: Text,
    bsSeq :: Int,
    bsStatus :: RunStatus,
    bsProjectHash :: Text,
    bsLastHost :: Maybe Text,
    bsLastResult :: Maybe Aeson.Value,
    bsAt :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON BoundarySnapshot where
  toJSON s =
    object
      [ "snapshot_format" .= s.bsFormat,
        "run_id" .= s.bsRunId,
        "seq" .= s.bsSeq,
        "status" .= s.bsStatus,
        "project_hash" .= s.bsProjectHash,
        "last_host" .= s.bsLastHost,
        "last_result" .= s.bsLastResult,
        "at" .= s.bsAt,
        -- Placeholder for M5 full machine encoding; keeps the key stable.
        "machine_json" .= object ["kind" .= String "boundary", "seq" .= s.bsSeq]
      ]

instance FromJSON BoundarySnapshot where
  parseJSON = withObject "BoundarySnapshot" $ \o ->
    BoundarySnapshot
      <$> o .: "snapshot_format"
      <*> o .: "run_id"
      <*> o .: "seq"
      <*> o .: "status"
      <*> o .: "project_hash"
      <*> o .:? "last_host"
      <*> o .:? "last_result"
      <*> o .: "at"

data RunStore = RunStore
  { rsRoot :: FilePath,
    rsRunId :: Text
  }
  deriving stock (Eq, Show)

-- | @<workspace>/.pml/runs/<run-id>/@
openRunStore :: FilePath -> Text -> IO RunStore
openRunStore workspaceRoot runId = do
  let root = workspaceRoot </> ".pml" </> "runs" </> T.unpack runId
  createDirectoryIfMissing True root
  pure (RunStore root runId)

snapshotPath :: RunStore -> FilePath
snapshotPath store = store.rsRoot </> "snapshot.json"

transitionsPath :: RunStore -> FilePath
transitionsPath store = store.rsRoot </> "transitions.jsonl"

writeBoundarySnapshot :: RunStore -> BoundarySnapshot -> IO ()
writeBoundarySnapshot store snap = do
  Aeson.encodeFile (snapshotPath store) snap
  let line =
        Aeson.encode $
          object
            [ "seq" .= snap.bsSeq,
              "host" .= snap.bsLastHost,
              "status" .= snap.bsStatus,
              "at" .= snap.bsAt
            ]
  LBS.appendFile (transitionsPath store) (line <> "\n")

readBoundarySnapshot :: RunStore -> IO (Maybe BoundarySnapshot)
readBoundarySnapshot store = do
  exists <- doesFileExist (snapshotPath store)
  if not exists
    then pure Nothing
    else do
      eresult <- Aeson.eitherDecodeFileStrict (snapshotPath store)
      pure $ case eresult of
        Left _ -> Nothing
        Right s -> Just s

-- | Lightweight JSON for last_result (no closures beyond a tag).
valueToJson :: V.Value -> Aeson.Value
valueToJson = \case
  V.VUnit -> object ["tag" .= String "unit"]
  V.VBool b -> object ["tag" .= String "bool", "v" .= b]
  V.VInt n -> object ["tag" .= String "int", "v" .= n]
  V.VFloat d -> object ["tag" .= String "float", "v" .= d]
  V.VString t -> object ["tag" .= String "string", "v" .= t]
  V.VList xs -> object ["tag" .= String "list", "v" .= map valueToJson xs]
  V.VRecord fs ->
    object
      [ "tag" .= String "record",
        "v"
          .= Aeson.Object
            ( KM.fromList
                [(Key.fromText (unIdent k), valueToJson v) | (k, v) <- fs]
            )
      ]
  V.VVariant (TypeName t) Nothing ->
    object ["tag" .= String "variant", "name" .= t]
  V.VVariant (TypeName t) (Just v) ->
    object ["tag" .= String "variant", "name" .= t, "v" .= valueToJson v]
  V.VClosure {} -> object ["tag" .= String "closure"]
  V.VBuiltin {} -> object ["tag" .= String "builtin"]
  V.VHostOp op -> object ["tag" .= String "host", "op" .= hostOpName op]

mkBoundary ::
  Text ->
  Int ->
  RunStatus ->
  Text ->
  Maybe HostOpId ->
  Maybe V.Value ->
  IO BoundarySnapshot
mkBoundary runId seqNo status projectHash mHost mResult = do
  now <- getCurrentTime
  let at = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
  pure
    BoundarySnapshot
      { bsFormat = 1,
        bsRunId = runId,
        bsSeq = seqNo,
        bsStatus = status,
        bsProjectHash = projectHash,
        bsLastHost = fmap hostOpName mHost,
        bsLastResult = fmap valueToJson mResult,
        bsAt = at
      }
