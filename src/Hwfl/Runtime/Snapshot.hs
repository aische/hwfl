-- | Run meta / snapshot codecs (M5). File layout lives in 'Hwfl.Runtime.Store'.
module Hwfl.Runtime.Snapshot
  ( RunMeta (..),
    RunSnapshot (..),
    valueToJson,
    valueFromJson,
    machineToJson,
    machineFromJson,
    statusText,
    snapshotToJson,
    parseMetaValue,
    parseSnapshotValue,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, (.!=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), QName (..), TypeName (..), qnameFromParts, qnameToText)
import Hwfl.Eval.Value (Env, HostOpId (..), ToolSpecValue (..), hostOpName)
import Hwfl.Eval.Value qualified as V
import Hwfl.Runtime.Turn
  ( parseToolCall,
    parseToolResult,
    parseTurn,
    toolCallToJson,
    toolResultToJson,
    turnToJson,
  )
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Machine
import Text.Read (readMaybe)

data RunMeta = RunMeta
  { rmRunId :: Text,
    rmProjectHash :: Text,
    rmEntry :: FilePath,
    rmStartedAt :: Text,
    rmStatus :: Text
  }
  deriving stock (Eq, Show)

data RunSnapshot = RunSnapshot
  { rsFormat :: Int,
    rsRunId :: Text,
    rsSeq :: Int,
    rsStatus :: MachineStatus,
    rsProjectHash :: Text,
    rsLastHost :: Maybe Text,
    rsLastResult :: Maybe Aeson.Value,
    rsAt :: Text,
    rsMachine :: Maybe Machine,
    -- | Innermost-first open span stack + monotonic counter for resume.
    rsSpanStack :: [Text],
    rsSpanCounter :: Int
  }
  deriving stock (Eq, Show)

parseMetaValue :: Aeson.Value -> Parser RunMeta
parseMetaValue = withObject "RunMeta" $ \o ->
  RunMeta
    <$> o .: "run_id"
    <*> o .: "project_hash"
    <*> o .: "entry"
    <*> o .: "started_at"
    <*> o .: "status"

snapshotToJson :: RunSnapshot -> Aeson.Value
snapshotToJson s =
  object
    [ "snapshot_format" .= s.rsFormat,
      "run_id" .= s.rsRunId,
      "seq" .= s.rsSeq,
      "status" .= statusText s.rsStatus,
      "project_hash" .= s.rsProjectHash,
      "last_host" .= s.rsLastHost,
      "last_result" .= s.rsLastResult,
      "at" .= s.rsAt,
      "machine_json" .= maybe (object ["kind" .= String "none"]) machineToJson s.rsMachine,
      "span_stack" .= s.rsSpanStack,
      "span_counter" .= s.rsSpanCounter
    ]

parseSnapshotValue :: Aeson.Value -> Parser RunSnapshot
parseSnapshotValue = withObject "RunSnapshot" $ \o -> do
  fmt <- o .: "snapshot_format"
  runId <- o .: "run_id"
  seqNo <- o .: "seq"
  stTxt <- o .: "status"
  hash <- o .: "project_hash"
  lastHost <- o .:? "last_host"
  lastRes <- o .:? "last_result"
  at <- o .: "at"
  mMachVal <- o .:? "machine_json"
  pauseVal <- case mMachVal of
    Just (Object km) -> pure (KM.lookup "pause" km)
    _ -> pure Nothing
  status <- parseStatus stTxt pauseVal
  machine <- case mMachVal of
    Nothing -> pure Nothing
    Just (Object km)
      | KM.lookup "kind" km == Just (String "none") -> pure Nothing
      | otherwise -> Just <$> parseMachine (Object km)
    Just v -> Just <$> parseMachine v
  spanStack <- o .:? "span_stack" .!= []
  spanCounter <- o .:? "span_counter" .!= 0
  pure (RunSnapshot fmt runId seqNo status hash lastHost lastRes at machine spanStack spanCounter)

-------------------------------------------------------------------------------
-- Status

statusText :: MachineStatus -> Text
statusText = \case
  MsRunning -> "running"
  MsDraining -> "draining"
  MsPaused PauseExplicit -> "paused"
  MsPaused (PauseAwaitingConfirm _) -> "awaiting_confirm"
  MsPaused (PauseAwaitingChoice _) -> "awaiting_choice"
  MsPaused (PauseAwaitingAsk _) -> "awaiting_input"
  MsPaused PauseCrashRecovery -> "paused"
  MsCompleted -> "completed"
  MsFailed -> "failed"

parseStatus :: Text -> Maybe Aeson.Value -> Parser MachineStatus
parseStatus txt pauseVal = case txt of
  "running" -> pure MsRunning
  "draining" -> pure MsDraining
  "completed" -> pure MsCompleted
  "failed" -> pure MsFailed
  "paused" -> case pauseVal of
    Just v -> MsPaused <$> parsePauseReason v
    Nothing -> pure (MsPaused PauseExplicit)
  "awaiting_confirm" -> case pauseVal of
    Just v -> MsPaused <$> parsePauseReason v
    Nothing ->
      pure (MsPaused (PauseAwaitingConfirm (ConfirmRequest "" "" Nothing)))
  "awaiting_choice" -> case pauseVal of
    Just v -> MsPaused <$> parsePauseReason v
    Nothing ->
      pure (MsPaused (PauseAwaitingChoice (ChoiceRequest "" "" [] Nothing)))
  "awaiting_input" -> case pauseVal of
    Just v -> MsPaused <$> parsePauseReason v
    Nothing ->
      pure (MsPaused (PauseAwaitingAsk (AskRequest "" "" Nothing)))
  other -> fail ("unknown status: " <> T.unpack other)

parsePauseReason :: Aeson.Value -> Parser PauseReason
parsePauseReason v =
  withObject
    "pause"
    ( \o -> do
        mReason <- o .:? "reason"
        case mReason :: Maybe Text of
          Just "explicit" -> pure PauseExplicit
          Just "crash" -> pure PauseCrashRecovery
          Just "awaiting_choice" -> PauseAwaitingChoice <$> parseChoiceObject o
          Just "awaiting_input" -> PauseAwaitingAsk <$> parseAskObject o
          Just "awaiting_confirm" -> PauseAwaitingConfirm <$> parseConfirmObject o
          _ ->
            case KM.lookup "options" o of
              Just _ -> PauseAwaitingChoice <$> parseChoiceObject o
              Nothing -> PauseAwaitingConfirm <$> parseConfirmObject o
    )
    v
    <|> pure PauseExplicit

-------------------------------------------------------------------------------
-- Machine codec

machineToJson :: Machine -> Aeson.Value
machineToJson m =
  object
    [ "status" .= statusText m.mStatus,
      "project_hash" .= m.mProjectHash,
      "current" .= currentToJson m.mCurrent,
      "frames" .= map frameToJson m.mFrames,
      "last_result" .= fmap valueToJson m.mLastResult,
      "error" .= fmap (T.pack . show) m.mError,
      "pause" .= pauseToJson m.mStatus
    ]

machineFromJson :: Aeson.Value -> Either String Machine
machineFromJson = parseEither parseMachine

parseMachine :: Aeson.Value -> Parser Machine
parseMachine = withObject "Machine" $ \o -> do
  stTxt <- o .: "status"
  pauseVal <- o .:? "pause"
  status <- parseStatus stTxt pauseVal
  hash <- o .: "project_hash"
  cur <- o .: "current" >>= parseCurrent
  frames <- o .: "frames" >>= mapM parseFrame
  lastRes <- o .:? "last_result"
  lastVal <- traverse parseValue lastRes
  errTxt <- o .:? "error"
  pure
    Machine
      { mStatus = status,
        mProjectHash = hash,
        mCurrent = cur,
        mFrames = frames,
        mLastResult = lastVal,
        mError = fmap ConfigErr errTxt
      }

pauseToJson :: MachineStatus -> Aeson.Value
pauseToJson = \case
  MsPaused (PauseAwaitingConfirm c) -> confirmToJson c
  MsPaused (PauseAwaitingChoice c) -> choiceToJson c
  MsPaused (PauseAwaitingAsk a) -> askToJson a
  MsPaused PauseExplicit -> object ["reason" .= String "explicit"]
  MsPaused PauseCrashRecovery -> object ["reason" .= String "crash"]
  _ -> Null

currentToJson :: Current -> Aeson.Value
currentToJson = \case
  CurEval e env ->
    object ["tag" .= String "eval", "expr" .= showText e, "env" .= envToJson env]
  CurReturn v -> object ["tag" .= String "return", "v" .= valueToJson v]
  CurHost op args ->
    object
      [ "tag" .= String "host",
        "op" .= hostOpName op,
        "args" .= map argValToJson args
      ]
  CurAwaitConfirm c ->
    object ["tag" .= String "await_confirm", "confirm" .= confirmToJson c]
  CurAwaitChoice c ->
    object ["tag" .= String "await_choice", "choice" .= choiceToJson c]
  CurAwaitAsk a ->
    object ["tag" .= String "await_ask", "ask" .= askToJson a]
  CurParPool -> object ["tag" .= String "par_pool"]
  CurCloseRegion sid v ->
    object ["tag" .= String "close_region", "span_id" .= sid, "v" .= valueToJson v]
  CurAgent ag -> object ["tag" .= String "agent", "agent" .= agentToJson ag]

parseCurrent :: Aeson.Value -> Parser Current
parseCurrent = withObject "Current" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "eval" -> CurEval <$> (o .: "expr" >>= readText) <*> (o .: "env" >>= parseEnv)
    "return" -> CurReturn <$> (o .: "v" >>= parseValue)
    "host" ->
      CurHost
        <$> (o .: "op" >>= parseHostOp)
        <*> (o .: "args" >>= mapM parseArgVal)
    "await_confirm" -> CurAwaitConfirm <$> (o .: "confirm" >>= parseConfirm)
    "await_choice" -> CurAwaitChoice <$> (o .: "choice" >>= parseChoice)
    "await_ask" -> CurAwaitAsk <$> (o .: "ask" >>= parseAsk)
    "par_pool" -> pure CurParPool
    "close_region" ->
      CurCloseRegion <$> o .: "span_id" <*> (o .: "v" >>= parseValue)
    "agent" -> CurAgent <$> (o .: "agent" >>= parseAgent)
    other -> fail ("unknown current: " <> T.unpack other)

agentToJson :: AgentState -> Aeson.Value
agentToJson ag =
  object $
    [ "system" .= ag.agSystem,
      "prompt" .= ag.agPrompt,
      "model" .= ag.agModel,
      "max_rounds" .= ag.agMaxRounds,
      "tools" .= map toolSpecToJson ag.agTools,
      "history" .= map turnToJson ag.agHistory,
      "round" .= ag.agRound,
      "tool_round" .= fmap toolRoundToJson ag.agToolRound,
      "span_id" .= ag.agSpanId,
      "round_span_id" .= ag.agRoundSpanId,
      "baseline_tools" .= map toolSpecToJson ag.agBaselineTools,
      "active_tool_ids" .= ag.agActiveToolIds,
      "loaded_instruction_ids" .= ag.agLoadedInstructionIds,
      "instruction_chars" .= ag.agInstructionChars,
      "round_close_attrs" .= ag.agRoundCloseAttrs
    ]
      ++ case ag.agSubmitSchema of
        Nothing -> []
        Just s -> ["submit_schema" .= s]

parseAgent :: Aeson.Value -> Parser AgentState
parseAgent = withObject "AgentState" $ \o ->
  AgentState
    <$> o .: "system"
    <*> o .: "prompt"
    <*> o .: "model"
    <*> o .: "max_rounds"
    <*> (o .: "tools" >>= mapM parseToolSpec)
    <*> o .:? "submit_schema"
    <*> (o .: "history" >>= mapM parseTurn)
    <*> o .: "round"
    <*> (o .:? "tool_round" >>= traverse parseToolRound)
    <*> o .: "span_id"
    <*> o .:? "round_span_id"
    <*> (o .:? "baseline_tools" >>= maybe (o .: "tools" >>= mapM parseToolSpec) (mapM parseToolSpec))
    <*> o .:? "active_tool_ids" .!= []
    <*> o .:? "loaded_instruction_ids" .!= []
    <*> o .:? "instruction_chars" .!= 0
    <*> o .:? "round_close_attrs"

toolRoundToJson :: ToolRound -> Aeson.Value
toolRoundToJson tr =
  object
    [ "pending" .= map toolCallToJson tr.trPending,
      "completed" .= map toolResultToJson tr.trCompleted,
      "active_call" .= fmap toolCallToJson tr.trActiveCall,
      "active_machine" .= fmap (machineToJson . unBranch) tr.trActiveMachine,
      "active_span_id" .= tr.trActiveSpanId
    ]

parseToolRound :: Aeson.Value -> Parser ToolRound
parseToolRound = withObject "ToolRound" $ \o ->
  ToolRound
    <$> (o .: "pending" >>= mapM parseToolCall)
    <*> (o .: "completed" >>= mapM parseToolResult)
    <*> (o .:? "active_call" >>= traverse parseToolCall)
    <*> (o .:? "active_machine" >>= traverse (fmap mkBranch . parseMachine))
    <*> o .:? "active_span_id"

toolSpecToJson :: ToolSpecValue -> Aeson.Value
toolSpecToJson ts =
  object
    [ "name" .= ts.tvsName,
      "description" .= ts.tvsDescription,
      "parameters" .= ts.tvsParameters,
      "callee" .= valueToJson ts.tvsCallee
    ]

parseToolSpec :: Aeson.Value -> Parser ToolSpecValue
parseToolSpec = withObject "ToolSpec" $ \o ->
  ToolSpecValue
    <$> o .: "name"
    <*> o .: "description"
    <*> o .: "parameters"
    <*> (o .: "callee" >>= parseValue)

frameToJson :: Frame -> Aeson.Value
frameToJson = \case
  FrLet n env body ->
    object
      [ "tag" .= String "let",
        "name" .= unIdent n,
        "env" .= envToJson env,
        "body" .= showText body
      ]
  FrAppFun env args ->
    object ["tag" .= String "app_fun", "env" .= envToJson env, "args" .= showText args]
  FrAppArgs f col env args ->
    object
      [ "tag" .= String "app_args",
        "fun" .= valueToJson f,
        "collected" .= map argValToJson col,
        "env" .= envToJson env,
        "args" .= showText args
      ]
  FrList acc env es ->
    object
      [ "tag" .= String "list",
        "acc" .= map valueToJson acc,
        "env" .= envToJson env,
        "rest" .= showText es
      ]
  FrRecord acc env fs ->
    object
      [ "tag" .= String "record",
        "acc" .= object [Key.fromText (unIdent k) .= valueToJson v | (k, v) <- acc],
        "env" .= envToJson env,
        "rest" .= showText fs
      ]
  FrInterp acc env parts ->
    object
      [ "tag" .= String "interp",
        "acc" .= acc,
        "env" .= envToJson env,
        "rest" .= showText parts
      ]
  FrProj f -> object ["tag" .= String "proj", "field" .= unIdent f]
  FrIndexE env ix ->
    object ["tag" .= String "index_e", "env" .= envToJson env, "ix" .= showText ix]
  FrIndexV v -> object ["tag" .= String "index_v", "v" .= valueToJson v]
  FrIf env t e ->
    object
      [ "tag" .= String "if",
        "env" .= envToJson env,
        "then" .= showText t,
        "else" .= showText e
      ]
  FrMatch env arms ->
    object ["tag" .= String "match", "env" .= envToJson env, "arms" .= showText arms]
  FrPar pjs -> object ["tag" .= String "par", "par" .= parToJson pjs]
  FrTry var handlerEnv handler ->
    object
      [ "tag" .= String "try",
        "var" .= unIdent var,
        "env" .= envToJson handlerEnv,
        "handler" .= showText handler
      ]
  FrConfirm c -> object ["tag" .= String "confirm", "confirm" .= confirmToJson c]
  FrChoice c -> object ["tag" .= String "choice", "choice" .= choiceToJson c]
  FrAsk a -> object ["tag" .= String "ask", "ask" .= askToJson a]
  FrAfterConfirm cur ->
    object ["tag" .= String "after_confirm", "current" .= currentToJson cur]
  FrExecApproved -> object ["tag" .= String "exec_approved"]
  FrRegion sid -> object ["tag" .= String "region", "span_id" .= sid]
  FrJoin acc env es ->
    object
      [ "tag" .= String "join",
        "acc" .= map valueToJson acc,
        "env" .= envToJson env,
        "rest" .= showText es
      ]

parseFrame :: Aeson.Value -> Parser Frame
parseFrame = withObject "Frame" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "let" ->
      (FrLet . Ident <$> (o .: "name"))
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "body" >>= readText)
    "app_fun" ->
      FrAppFun <$> (o .: "env" >>= parseEnv) <*> (o .: "args" >>= readText)
    "app_args" ->
      FrAppArgs
        <$> (o .: "fun" >>= parseValue)
        <*> (o .: "collected" >>= mapM parseArgVal)
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "args" >>= readText)
    "list" ->
      FrList
        <$> (o .: "acc" >>= mapM parseValue)
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "rest" >>= readText)
    "record" ->
      FrRecord
        <$> (o .: "acc" >>= parseRecordFields)
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "rest" >>= readText)
    "interp" ->
      FrInterp
        <$> o .: "acc"
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "rest" >>= readText)
    "proj" -> FrProj . Ident <$> o .: "field"
    "index_e" ->
      FrIndexE <$> (o .: "env" >>= parseEnv) <*> (o .: "ix" >>= readText)
    "index_v" -> FrIndexV <$> (o .: "v" >>= parseValue)
    "if" ->
      FrIf
        <$> (o .: "env" >>= parseEnv)
        <*> (o .: "then" >>= readText)
        <*> (o .: "else" >>= readText)
    "match" ->
      FrMatch <$> (o .: "env" >>= parseEnv) <*> (o .: "arms" >>= readText)
    "par" -> FrPar <$> (o .: "par" >>= parsePar)
    "try" ->
      (FrTry . Ident <$> (o .: "var"))
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "handler" >>= readText)
    "confirm" -> FrConfirm <$> (o .: "confirm" >>= parseConfirm)
    "choice" -> FrChoice <$> (o .: "choice" >>= parseChoice)
    "ask" -> FrAsk <$> (o .: "ask" >>= parseAsk)
    "after_confirm" -> FrAfterConfirm <$> (o .: "current" >>= parseCurrent)
    "exec_approved" -> pure FrExecApproved
    "region" -> FrRegion <$> o .: "span_id"
    "join" ->
      FrJoin
        <$> (o .: "acc" >>= mapM parseValue)
        <*> (o .: "env" >>= parseEnv)
        <*> (o .: "rest" >>= readText)
    other -> fail ("unknown frame: " <> T.unpack other)

parToJson :: ParJoinState -> Aeson.Value
parToJson p =
  object
    [ "var" .= unIdent p.pjsVar,
      "body" .= showText p.pjsBody,
      "max" .= p.pjsMax,
      "on_error" .= onErrText p.pjsOnError,
      "items" .= map valueToJson p.pjsItems,
      "slots" .= map slotToJson p.pjsSlots,
      "active"
        .= object
          [ Key.fromText (T.pack (show i)) .= machineToJson (unBranch b)
            | (i, b) <- Map.toList p.pjsActive
          ],
      "next" .= p.pjsNextIndex,
      "phase" .= phaseText p.pjsPhase,
      "confirm_queue" .= map confirmToJson p.pjsConfirmQueue,
      "choice_queue" .= map choiceToJson p.pjsChoiceQueue,
      "ask_queue" .= map askToJson p.pjsAskQueue,
      "parent_env" .= envToJson p.pjsParentEnv
    ]

onErrText :: ParOnError -> Text
onErrText = \case
  ParFail -> "fail"
  ParCollect -> "collect"

parsePar :: Aeson.Value -> Parser ParJoinState
parsePar = withObject "ParJoinState" $ \o -> do
  var <- Ident <$> o .: "var"
  body <- o .: "body" >>= readText
  mx <- o .: "max"
  onE <- o .: "on_error"
  items <- o .: "items" >>= mapM parseValue
  slots <- o .: "slots" >>= mapM parseSlot
  active <- o .: "active" >>= parseActive
  next <- o .: "next"
  phase <- o .: "phase" >>= parsePhase
  cq <- o .: "confirm_queue" >>= mapM parseConfirm
  chq <- o .:? "choice_queue" .!= [] >>= mapM parseChoice
  aq <- o .:? "ask_queue" .!= [] >>= mapM parseAsk
  penv <- o .: "parent_env" >>= parseEnv
  let onErr = if onE == ("collect" :: Text) then ParCollect else ParFail
  pure
    ParJoinState
      { pjsVar = var,
        pjsBody = body,
        pjsMax = mx,
        pjsOnError = onErr,
        pjsItems = items,
        pjsSlots = slots,
        pjsActive = active,
        pjsNextIndex = next,
        pjsPhase = phase,
        pjsConfirmQueue = cq,
        pjsChoiceQueue = chq,
        pjsAskQueue = aq,
        pjsParentEnv = penv
      }

parseActive :: Aeson.Value -> Parser (Map Int BranchMachine)
parseActive = withObject "active" $ \km ->
  Map.fromList <$> traverse
      ( \(k, v) -> do
          m <- parseMachine v
          case readMaybe (T.unpack (Key.toText k)) of
            Just i -> pure (i, mkBranch m)
            Nothing -> fail "bad active key"
      )
      (KM.toList km)

phaseText :: ParPoolPhase -> Text
phaseText = \case
  ParScheduling -> "scheduling"
  ParDraining -> "draining"
  ParPausedConfirm -> "paused_confirm"

parsePhase :: Text -> Parser ParPoolPhase
parsePhase = \case
  "scheduling" -> pure ParScheduling
  "draining" -> pure ParDraining
  "paused_confirm" -> pure ParPausedConfirm
  other -> fail ("bad phase: " <> T.unpack other)

slotToJson :: ParSlot -> Aeson.Value
slotToJson = \case
  ParSlotPending -> object ["tag" .= String "pending"]
  ParSlotRunning -> object ["tag" .= String "running"]
  ParSlotDone v -> object ["tag" .= String "done", "v" .= valueToJson v]
  ParSlotFailed t -> object ["tag" .= String "failed", "msg" .= t]
  ParSlotAwaitingConfirm c ->
    object ["tag" .= String "awaiting_confirm", "confirm" .= confirmToJson c]
  ParSlotAwaitingChoice c ->
    object ["tag" .= String "awaiting_choice", "choice" .= choiceToJson c]
  ParSlotAwaitingAsk a ->
    object ["tag" .= String "awaiting_ask", "ask" .= askToJson a]

parseSlot :: Aeson.Value -> Parser ParSlot
parseSlot = withObject "ParSlot" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "pending" -> pure ParSlotPending
    "running" -> pure ParSlotRunning
    "done" -> ParSlotDone <$> (o .: "v" >>= parseValue)
    "failed" -> ParSlotFailed <$> o .: "msg"
    "awaiting_confirm" -> ParSlotAwaitingConfirm <$> (o .: "confirm" >>= parseConfirm)
    "awaiting_choice" -> ParSlotAwaitingChoice <$> (o .: "choice" >>= parseChoice)
    "awaiting_ask" -> ParSlotAwaitingAsk <$> (o .: "ask" >>= parseAsk)
    other -> fail ("bad slot: " <> T.unpack other)

confirmToJson :: ConfirmRequest -> Aeson.Value
confirmToJson c =
  object
    [ "title" .= c.crTitle,
      "detail" .= c.crDetail,
      "branch_index" .= c.crBranchIndex,
      "reason" .= String "awaiting_confirm"
    ]

parseConfirm :: Aeson.Value -> Parser ConfirmRequest
parseConfirm = withObject "ConfirmRequest" parseConfirmObject

parseConfirmObject :: Aeson.Object -> Parser ConfirmRequest
parseConfirmObject o =
  ConfirmRequest
    <$> o .: "title"
    <*> (o .:? "detail" .!= "")
    <*> o .:? "branch_index"

choiceToJson :: ChoiceRequest -> Aeson.Value
choiceToJson c =
  object
    [ "title" .= c.chTitle,
      "detail" .= c.chDetail,
      "options" .= c.chOptions,
      "branch_index" .= c.chBranchIndex,
      "reason" .= String "awaiting_choice"
    ]

parseChoice :: Aeson.Value -> Parser ChoiceRequest
parseChoice = withObject "ChoiceRequest" parseChoiceObject

parseChoiceObject :: Aeson.Object -> Parser ChoiceRequest
parseChoiceObject o =
  ChoiceRequest
    <$> o .: "title"
    <*> (o .:? "detail" .!= "")
    <*> (o .:? "options" .!= [])
    <*> o .:? "branch_index"

askToJson :: AskRequest -> Aeson.Value
askToJson a =
  object
    [ "prompt" .= a.askPrompt,
      "detail" .= a.askDetail,
      "branch_index" .= a.askBranchIndex,
      "reason" .= String "awaiting_input"
    ]

parseAsk :: Aeson.Value -> Parser AskRequest
parseAsk = withObject "AskRequest" parseAskObject

parseAskObject :: Aeson.Object -> Parser AskRequest
parseAskObject o =
  AskRequest
    <$> o .: "prompt"
    <*> (o .:? "detail" .!= "")
    <*> o .:? "branch_index"

envToJson :: Env -> Aeson.Value
envToJson env =
  object [Key.fromText (unIdent k) .= valueToJson v | (k, v) <- Map.toList env]

parseEnv :: Aeson.Value -> Parser Env
parseEnv = withObject "Env" $ \km ->
  Map.fromList <$> traverse
      (\(k, v) -> (Ident (Key.toText k),) <$> parseValue v)
      (KM.toList km)

argValToJson :: (Maybe Ident, V.Value) -> Aeson.Value
argValToJson (mn, v) =
  object ["name" .= fmap unIdent mn, "v" .= valueToJson v]

parseArgVal :: Aeson.Value -> Parser (Maybe Ident, V.Value)
parseArgVal = withObject "arg" $ \o -> do
  mn <- o .:? "name"
  v <- o .: "v" >>= parseValue
  pure (fmap Ident mn, v)

parseRecordFields :: Aeson.Value -> Parser [(Ident, V.Value)]
parseRecordFields = withObject "record fields" $ \km ->
  traverse (\(k, v) -> (Ident (Key.toText k),) <$> parseValue v) (KM.toList km)

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
        "v" .= object [Key.fromText (unIdent k) .= valueToJson v | (k, v) <- fs]
      ]
  V.VVariant (TypeName t) Nothing -> object ["tag" .= String "variant", "name" .= t]
  V.VVariant (TypeName t) (Just v) ->
    object ["tag" .= String "variant", "name" .= t, "v" .= valueToJson v]
  -- Secrets never hit disk in cleartext (spec §07 §4).
  V.VSecret _ -> object ["tag" .= String "secret", "v" .= String "[REDACTED]"]
  V.VClosure ps body env ->
    object
      [ "tag" .= String "closure",
        "params" .= showText ps,
        "body" .= showText body,
        "env" .= envToJson env
      ]
  V.VTopFun (Ident n) -> object ["tag" .= String "topfun", "name" .= n]
  V.VBuiltin b -> object ["tag" .= String "builtin", "op" .= showText b]
  V.VHostOp op -> object ["tag" .= String "host", "op" .= hostOpName op]
  V.VToolSpec ts -> object ["tag" .= String "tool_spec", "tool" .= toolSpecToJson ts]
  V.VSkillMain q ->
    object ["tag" .= String "skill_main", "qname" .= qnameToText q]
  V.VSchema schema -> object ["tag" .= String "schema", "v" .= schema]
  V.VTurn t -> object ["tag" .= String "turn", "v" .= turnToJson t]

valueFromJson :: Aeson.Value -> Either String V.Value
valueFromJson = parseEither parseValue

parseValue :: Aeson.Value -> Parser V.Value
parseValue = withObject "Value" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "unit" -> pure V.VUnit
    "bool" -> V.VBool <$> o .: "v"
    "int" -> V.VInt <$> o .: "v"
    "float" -> V.VFloat <$> o .: "v"
    "string" -> V.VString <$> o .: "v"
    "list" -> V.VList <$> (o .: "v" >>= mapM parseValue)
    "record" -> V.VRecord <$> (o .: "v" >>= parseRecordFields)
    "variant" -> do
      n <- TypeName <$> o .: "name"
      mv <- o .:? "v"
      V.VVariant n <$> traverse parseValue mv
    "secret" -> pure (V.VSecret (V.VString "[REDACTED]"))
    "closure" ->
      V.VClosure
        <$> (o .: "params" >>= readText)
        <*> (o .: "body" >>= readText)
        <*> (o .: "env" >>= parseEnv)
    "topfun" -> V.VTopFun . Ident <$> o .: "name"
    "builtin" -> V.VBuiltin <$> (o .: "op" >>= readText)
    "host" -> V.VHostOp <$> (o .: "op" >>= parseHostOp)
    "tool_spec" -> V.VToolSpec <$> (o .: "tool" >>= parseToolSpec)
    "skill_main" -> V.VSkillMain . qnameFromText <$> o .: "qname"
    "schema" -> V.VSchema <$> o .: "v"
    "turn" -> V.VTurn <$> (o .: "v" >>= parseTurn)
    other -> fail ("unknown value tag: " <> T.unpack other)

parseHostOp :: Text -> Parser HostOpId
parseHostOp = \case
  "fs.read" -> pure HostFsRead
  "fs.write" -> pure HostFsWrite
  "fs.find" -> pure HostFsFind
  "fs.list" -> pure HostFsList
  "fs.edit" -> pure HostFsEdit
  "fs.patch" -> pure HostFsPatch
  "fs.grep" -> pure HostFsGrep
  "fs.read_slice" -> pure HostFsReadSlice
  "fs.remove" -> pure HostFsRemove
  "fs.mkdir" -> pure HostFsMkdir
  "fs.copy" -> pure HostFsCopy
  "fs.move" -> pure HostFsMove
  "fs.exists" -> pure HostFsExists
  "fs.stat" -> pure HostFsStat
  "exec.run" -> pure HostExecRun
  "llm.chat" -> pure HostLlmChat
  "llm.chat_messages" -> pure HostLlmChatMessages
  "llm.object" -> pure HostLlmObject
  "llm.agent" -> pure HostLlmAgent
  "llm.agent_object" -> pure HostLlmAgentObject
  "human.confirm" -> pure HostHumanConfirm
  "human.choice" -> pure HostHumanChoice
  "human.ask" -> pure HostHumanAsk
  "obs.log" -> pure HostObsLog
  "obs.span" -> pure HostObsSpan
  "meta.check_module" -> pure HostMetaCheckModule
  "meta.check_project" -> pure HostMetaCheckProject
  "meta.invoke" -> pure HostMetaInvoke
  "meta.list_runs" -> pure HostMetaListRuns
  "meta.read_spans" -> pure HostMetaReadSpans
  "meta.read_snapshot" -> pure HostMetaReadSnapshot
  "skill.discover" -> pure HostSkillDiscover
  "skill.load" -> pure HostSkillLoad
  other -> fail ("unknown host op: " <> T.unpack other)

qnameFromText :: Text -> QName
qnameFromText t = qnameFromParts (T.splitOn "/" t)

showText :: (Show a) => a -> Text
showText = T.pack . show

readText :: (Read a) => Text -> Parser a
readText t = case readMaybe (T.unpack t) of
  Just a -> pure a
  Nothing -> fail ("read failed: " <> T.unpack (T.take 80 t))
