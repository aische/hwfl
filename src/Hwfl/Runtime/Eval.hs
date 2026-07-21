-- | Frame/CEK host runtime: big-step pure crunch, small-step host/par/confirm.
module Hwfl.Runtime.Eval
  ( RunCtx (..),
    StepMode (..),
    StepResult (..),
    stepMachine,
    runUntilPause,
    approveMachine,
    chooseMachine,
    replyMachine,
    extendAgentMachine,
    evalIO,
    applyIO,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.IORef (IORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Expr
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..), SchemaDoc)
import Hwfl.Ast.Name (Ident (..), QName (..), Slug, qnameFromParts, qnameToText, slugToText)
import Hwfl.Ast.Pat (Literal (..))
import Hwfl.Ast.Skill (SkillMeta (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env (TypeEnv)
import Hwfl.Check.Error (renderCheckError)
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Check.Schema (typeToSchema, typeToSchemaWithDocs)
import Hwfl.Eval.Error (EvalError (..))
import Hwfl.Eval.Prelude (applyBuiltin)
import Hwfl.Eval.Pure (bindParams, matchPat)
import Hwfl.Eval.Value
import Data.Aeson.KeyMap qualified as KM
import Hwfl.Llm.Pricing (providerRoundCloseAttrs)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types
  ( ChatRequest (..),
    ProviderResult (..),
    ToolCall (..),
    ToolResult (..),
    Turn (..),
    emptyChatRequest,
    renderProviderError,
  )
import Hwfl.Obs.Redact (hostOpenAttrs, toolCallOpenAttrs)
import Hwfl.Obs.Span (SpanKind (..), SpanStatus (..))
import Hwfl.Obs.Stream (StreamSink (..), newStreamSink)
import Hwfl.Obs.Trace
  ( SpanState (..),
    appendEvent,
    closeSpan,
    getSpanStack,
    openSpan,
  )
import Hwfl.Runtime.Agent
  ( buildToolSpec,
    coerceToolArgs,
    initAgentState,
    isSubmitCall,
    lookupTool,
    mixesSubmit,
    parseAgentArgs,
    parseAgentObjectArgs,
    providerToolSpecs,
    sanitizeToolName,
    submitToolName,
    validateSubmit,
    valueToJsonText,
  )
import Hwfl.Runtime.Error (RuntimeError (..), isCatchable, renderRuntimeError)
import Hwfl.Runtime.Host (HostEnv (..), HostResult (..), execNeedsConfirm, runHostOp)
import Hwfl.Runtime.Machine
import Hwfl.Runtime.Skills
  ( AgentSkillLoad (..),
    agentLoadSkill,
    instructionInjectionText,
  )
import Hwfl.Runtime.Turn (turnsToValue)
import Hwfl.Runtime.Store (RunStore, persistTransition)
import Hwfl.SkillCatalog (SkillEntry (..), lookupSkillEntry)

data RunCtx = RunCtx
  { rcHost :: HostEnv,
    rcSections :: Map Slug Text,
    rcFuns :: FunTable,
    rcBaseEnv :: Env,
    -- | Module type aliases for @schema(T)@ reflection at runtime.
    rcTypeEnv :: TypeEnv,
    rcSchemaDocs :: [SchemaDoc],
    rcStore :: RunStore,
    rcProjectHash :: Text,
    rcSeq :: IORef Int,
    rcSpans :: SpanState,
    -- | Prebuilt env+funs for callable skills (keyed by skill qname).
    rcSkillFuns :: Map QName (Env, FunTable),
    -- | Loaded skill modules for tool schema / body rebuild.
    rcSkillModules :: Map QName LoadedModule,
    -- | Prebuilt env+funs for callable entry modules (same-project; E11).
    rcEntryModules :: Map QName (Env, FunTable),
    -- | Nest depth while stepping a 'BranchMachine' (agent tool / FrInvoke / par).
    -- Snapshot writes are suppressed when > 0 so a bare branch never overwrites
    -- root @snapshot.json@; the outer wrapper persists the full machine.
    rcNestDepth :: Int
  }

-- | Step a nested branch under the same run store without root snapshot writes.
nestedCtx :: RunCtx -> RunCtx
nestedCtx ctx = ctx {rcNestDepth = ctx.rcNestDepth + 1}

data StepMode = StepOnce | StepRun
  deriving stock (Eq, Show)

data StepResult = StepResult
  { srMachine :: Machine,
    srTransitioned :: Bool
  }
  deriving stock (Eq, Show)

mapEval :: Either EvalError a -> Either RuntimeError a
mapEval = either (Left . EvalErr) Right

-------------------------------------------------------------------------------
-- Compatibility

evalIO :: RunCtx -> Env -> Expr -> IO (Either RuntimeError Value)
evalIO ctx env expr = do
  m1 <- runUntilPause ctx StepRun (initialMachine ctx.rcProjectHash (CurEval expr env))
  pure (resultOf m1)

applyIO ::
  RunCtx ->
  Value ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError Value)
applyIO ctx f args = case openApply ctx f args of
  Left e -> pure (Left e)
  Right (CurEval body env) -> evalIO ctx env body
  Right (CurReturn v) -> pure (Right v)
  Right (CurHost op argv)
    | op == HostHumanConfirm ->
        pure (Left (EvalErr (Unsupported "human.confirm requires the machine driver")))
    | op == HostHumanChoice ->
        pure (Left (EvalErr (Unsupported "human.choice requires the machine driver")))
    | op == HostHumanAsk ->
        pure (Left (EvalErr (Unsupported "human.ask requires the machine driver")))
    | op == HostObsSpan ->
        pure (Left (EvalErr (Unsupported "obs.span requires the machine driver")))
    | op == HostLlmAgent ->
        pure (Left (EvalErr (Unsupported "llm.agent requires the machine driver")))
    | op == HostLlmAgentObject ->
        pure (Left (EvalErr (Unsupported "llm.agent_object requires the machine driver")))
    | otherwise -> do
        result <- runHostOp ctx.rcHost op argv
        case result of
          Left e -> do
            _ <- persist ctx (Just op) Nothing MsFailed Nothing
            pure (Left e)
          Right hr -> do
            _ <- persist ctx (Just op) (Just hr.hrValue) MsRunning Nothing
            pure (Right hr.hrValue)
  Right (CurEntryInvoke q _) ->
    pure (Left (EvalErr (Unsupported ("entry invoke requires the machine driver: " <> qnameToText q))))
  Right c ->
    pure (Left (EvalErr (Trap ("applyIO: unexpected " <> T.pack (show c)))))

resultOf :: Machine -> Either RuntimeError Value
resultOf m = case m.mStatus of
  MsCompleted -> maybe (Left (EvalErr (Trap "completed without result"))) Right m.mLastResult
  MsFailed -> Left (fromMaybe (EvalErr (Trap "failed")) m.mError)
  MsPaused (PauseAwaitingConfirm _) ->
    Left (EvalErr (Unsupported "paused on confirm; use approve/resume"))
  MsPaused (PauseAwaitingChoice _) ->
    Left (EvalErr (Unsupported "paused on choice; use choose"))
  MsPaused (PauseAwaitingAsk _) ->
    Left (EvalErr (Unsupported "paused on ask; use reply"))
  MsPaused (PauseAwaitingAgent _) ->
    Left (EvalErr (Unsupported "paused on agent budget; use extend"))
  other -> Left (EvalErr (Trap ("stopped: " <> T.pack (show other))))

openApply ::
  RunCtx ->
  Value ->
  [(Maybe Ident, Value)] ->
  Either RuntimeError Current
openApply ctx fv argv = case fv of
  VBuiltin BTool -> case map snd argv of
    [callee] -> CurReturn <$> buildToolSpec ctx.rcFuns callee
    _ -> Left (HostErr "tool() expects one function argument")
  VBuiltin b -> CurReturn <$> mapEval (applyBuiltin b (map snd argv))
  VClosure params body cloEnv -> case bindParams params argv of
    Left e -> Left (EvalErr e)
    Right binds -> Right (CurEval body (extendEnvMany binds cloEnv))
  VTopFun n -> case Map.lookup n ctx.rcFuns of
    Nothing -> Left (EvalErr (Trap ("unknown top-level fun: " <> unIdent n)))
    Just (params, body) -> case bindParams params argv of
      Left e -> Left (EvalErr e)
      Right binds -> Right (CurEval body (extendEnvMany binds ctx.rcBaseEnv))
  VSkillMain q -> case Map.lookup q ctx.rcSkillFuns of
    Nothing -> Left (EvalErr (Trap ("unknown skill module: " <> qnameToText q)))
    Just (env, funs) -> case Map.lookup (Ident "main") funs of
      Nothing -> Left (EvalErr (Trap ("skill missing main: " <> qnameToText q)))
      Just (params, body) -> case bindParams params argv of
        Left e -> Left (EvalErr e)
        Right binds -> Right (CurEval body (extendEnvMany binds env))
  -- Same-project entry call (E11): the caller drives a nested BranchMachine.
  VEntryMain q -> Right (CurEntryInvoke q argv)
  VHostOp op -> Right (CurHost op argv)
  _ -> Left (EvalErr (Trap "applied a non-function value"))

-------------------------------------------------------------------------------
-- Driver

runUntilPause :: RunCtx -> StepMode -> Machine -> IO Machine
runUntilPause ctx mode = go
  where
    go m = case m.mStatus of
      MsCompleted -> pure m
      MsFailed -> pure m
      MsPaused _ -> pure m
      _ -> do
        er <- stepMachine ctx mode m
        case er of
          Left err -> pure m {mStatus = MsFailed, mError = Just err}
          Right sr ->
            let m' = sr.srMachine
             in case mode of
                  StepOnce
                    | sr.srTransitioned || isTerminal m' -> pure m'
                    | otherwise -> go m'
                  StepRun
                    | isTerminal m' -> pure m'
                    | otherwise -> go m'

isTerminal :: Machine -> Bool
isTerminal m = case m.mStatus of
  MsCompleted -> True
  MsFailed -> True
  MsPaused _ -> True
  _ -> False

stepMachine :: RunCtx -> StepMode -> Machine -> IO (Either RuntimeError StepResult)
stepMachine ctx mode m = case m.mStatus of
  MsCompleted -> pure (Right (StepResult m False))
  MsFailed -> pure (Right (StepResult m False))
  MsPaused _ -> pure (Right (StepResult m False))
  MsRunning -> afterCrunch
  MsDraining -> afterCrunch
  where
    afterCrunch = case crunch ctx m of
      Left e -> abortOrCatch ctx mode m e
      Right m' -> case m'.mCurrent of
        CurHost op args -> doHost ctx mode m' op args
        CurAwaitConfirm c -> doConfirm ctx m' c
        CurAwaitChoice c -> doChoice ctx m' c
        CurAwaitAsk a -> doAsk ctx m' a
        CurParPool -> stepPar ctx mode m'
        CurCloseRegion sid v -> doCloseRegion ctx mode m' sid v
        CurAgent ag -> stepAgent ctx mode m' ag
        CurEntryInvoke q argv -> doEntryInvoke ctx mode m' q argv
        CurInvoke -> stepInvoke ctx mode m'
        CurReturn v | null m'.mFrames -> doComplete ctx mode m' v
        _ -> pure (Right (StepResult m' False))

doCloseRegion ::
  RunCtx -> StepMode -> Machine -> Text -> Value -> IO (Either RuntimeError StepResult)
doCloseRegion ctx mode m sid v = do
  closeSpan ctx.rcStore ctx.rcSpans sid SsOk (object []) Nothing
  let m' = m {mCurrent = CurReturn v}
  -- Continue reducing the returned value into remaining frames / complete.
  stepMachine ctx mode m'

doComplete ::
  RunCtx -> StepMode -> Machine -> Value -> IO (Either RuntimeError StepResult)
doComplete ctx mode m v = do
  let m' = m {mStatus = MsCompleted, mLastResult = Just v}
  _ <- persist ctx Nothing (Just v) MsCompleted (Just m')
  pure (Right (StepResult (pauseIfStep mode m') True))

doConfirm ::
  RunCtx -> Machine -> ConfirmRequest -> IO (Either RuntimeError StepResult)
doConfirm ctx m c = do
  let m' = m {mStatus = MsPaused (PauseAwaitingConfirm c), mCurrent = CurAwaitConfirm c}
  _ <-
    openSpan
      ctx.rcStore
      ctx.rcSpans
      "human.confirm"
      SkHost
      (hostOpenAttrs HostHumanConfirm [(Just (Ident "title"), VString c.crTitle)])
  -- Leave host span open across the pause; closed on approve.
  _ <- persist ctx (Just HostHumanConfirm) Nothing (MsPaused (PauseAwaitingConfirm c)) (Just m')
  pure (Right (StepResult m' True))

doChoice ::
  RunCtx -> Machine -> ChoiceRequest -> IO (Either RuntimeError StepResult)
doChoice ctx m c = do
  let m' = m {mStatus = MsPaused (PauseAwaitingChoice c), mCurrent = CurAwaitChoice c}
  _ <-
    openSpan
      ctx.rcStore
      ctx.rcSpans
      "human.choice"
      SkHost
      ( hostOpenAttrs
          HostHumanChoice
          [ (Just (Ident "title"), VString c.chTitle),
            (Just (Ident "options"), VList (map VString c.chOptions))
          ]
      )
  _ <- persist ctx (Just HostHumanChoice) Nothing (MsPaused (PauseAwaitingChoice c)) (Just m')
  pure (Right (StepResult m' True))

doAsk ::
  RunCtx -> Machine -> AskRequest -> IO (Either RuntimeError StepResult)
doAsk ctx m a = do
  let m' = m {mStatus = MsPaused (PauseAwaitingAsk a), mCurrent = CurAwaitAsk a}
  _ <-
    openSpan
      ctx.rcStore
      ctx.rcSpans
      "human.ask"
      SkHost
      (hostOpenAttrs HostHumanAsk [(Just (Ident "prompt"), VString a.askPrompt)])
  _ <- persist ctx (Just HostHumanAsk) Nothing (MsPaused (PauseAwaitingAsk a)) (Just m')
  pure (Right (StepResult m' True))

doHost ::
  RunCtx ->
  StepMode ->
  Machine ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError StepResult)
doHost ctx mode m op args
  | op == HostHumanConfirm = case confirmArgs args of
      Left e -> abortOrCatch ctx mode m e
      Right c -> doConfirm ctx m c
  | op == HostHumanChoice = case choiceArgs args of
      Left e -> abortOrCatch ctx mode m e
      Right c -> doChoice ctx m c
  | op == HostHumanAsk = case askArgs args of
      Left e -> abortOrCatch ctx mode m e
      Right a -> doAsk ctx m a
  | op == HostExecRun =
      case m.mFrames of
        FrExecApproved : rest ->
          doHostRun ctx mode (m {mFrames = rest}) op args
        _
          | execNeedsConfirm ctx.rcHost -> doExecConfirm ctx m args
          | otherwise -> doHostRun ctx mode m op args
  | op == HostObsSpan = case parseObsSpan args of
      Right _ -> doObsSpan ctx mode m args
      Left e ->
        -- Curried surface @obs.span(name)(thunk)@: first app yields CurHost with
        -- only the name while FrAppFun still holds the thunk — collect it.
        case m.mFrames of
          FrAppFun env more : rest
            | obsSpanNeedsBody args,
              not (null more) ->
                case applyOrArgs ctx m (VHostOp HostObsSpan) args env more rest of
                  Left err -> abortOrCatch ctx mode m err
                  Right (Just m') -> pure (Right (StepResult m' False))
                  Right Nothing -> pure (Right (StepResult m False))
          _ -> abortOrCatch ctx mode m e
  | op == HostObsLog = doObsLog ctx mode m args
  | op == HostLlmAgent = startAgent ctx mode m args Nothing
  | op == HostLlmAgentObject = case parseAgentObjectArgs args of
      Left e -> abortOrCatch ctx mode m e
      Right (system, prompt, tools, schema, model, maxRounds, history) ->
        startAgentPrepared
          ctx
          mode
          m
          HostLlmAgentObject
          args
          system
          prompt
          tools
          model
          maxRounds
          (Just schema)
          history
  | otherwise = doHostRun ctx mode m op args

-- | Open span, run host op, close span (standard host transition).
-- For @llm.chat@, attaches a coalescing stream sink to the open span.
doHostRun ::
  RunCtx ->
  StepMode ->
  Machine ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError StepResult)
doHostRun ctx mode m op args = do
  sid <-
    openSpan
      ctx.rcStore
      ctx.rcSpans
      (hostOpName op)
      SkHost
      (hostOpenAttrs op args)
  (host, flushStream) <- attachLlmStream ctx op
  result <- runHostOp host op args
  flushStream
  case result of
    Left e -> do
      abortOrCatch ctx mode m e >>= \case
        Right sr -> do
          mSeq <- persist ctx (Just op) Nothing sr.srMachine.mStatus (Just sr.srMachine)
          closeSpan ctx.rcStore ctx.rcSpans sid SsError (object ["error" .= renderErr e]) mSeq
          pure (Right sr)
        Left _ -> do
          let m' = m {mStatus = MsFailed, mError = Just e}
          mSeq <- persist ctx (Just op) Nothing MsFailed (Just m')
          closeSpan ctx.rcStore ctx.rcSpans sid SsError (object ["error" .= renderErr e]) mSeq
          pure (Left e)
    Right hr -> do
      let m' = pauseIfStep mode (m {mCurrent = CurReturn hr.hrValue})
      mSeq <- persist ctx (Just op) (Just hr.hrValue) m'.mStatus (Just m')
      closeSpan ctx.rcStore ctx.rcSpans sid SsOk hr.hrCloseAttrs mSeq
      pure (Right (StepResult m' True))

-- | Wire a progressive chunk sink for @llm.chat@ only (not @llm.object@).
attachLlmStream :: RunCtx -> HostOpId -> IO (HostEnv, IO ())
attachLlmStream ctx = \case
  HostLlmChat -> do
    sink <- newStreamSink ctx.rcStore ctx.rcSpans
    pure
      ( ctx.rcHost {heLlmOnChunk = Just sink.ssOnChunk},
        sink.ssFlush
      )
  HostLlmChatMessages -> do
    sink <- newStreamSink ctx.rcStore ctx.rcSpans
    pure
      ( ctx.rcHost {heLlmOnChunk = Just sink.ssOnChunk},
        sink.ssFlush
      )
  _ -> pure (ctx.rcHost {heLlmOnChunk = Nothing}, pure ())

-- | Pause for human confirm before @exec.run@ when @exec.confirm@ is true.
doExecConfirm ::
  RunCtx ->
  Machine ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError StepResult)
doExecConfirm ctx m args =
  let program = case lookup (Just (Ident "program")) args of
        Just (VString p) -> p
        _ -> "exec"
      detailArgs = case lookup (Just (Ident "args")) args of
        Just (VList xs) ->
          T.intercalate " " [t | VString t <- xs]
        _ -> ""
      c =
        ConfirmRequest
          { crTitle = "exec.run " <> program,
            crDetail = detailArgs,
            crBranchIndex = Nothing
          }
      m' =
        m
          { mStatus = MsPaused (PauseAwaitingConfirm c),
            mCurrent = CurAwaitConfirm c,
            mFrames = FrAfterConfirm (CurHost HostExecRun args) : m.mFrames
          }
   in do
        _ <-
          openSpan
            ctx.rcStore
            ctx.rcSpans
            "human.confirm"
            SkHost
            (hostOpenAttrs HostHumanConfirm [(Just (Ident "title"), VString c.crTitle)])
        _ <- persist ctx (Just HostHumanConfirm) Nothing (MsPaused (PauseAwaitingConfirm c)) (Just m')
        pure (Right (StepResult m' True))

-------------------------------------------------------------------------------
-- Agent loop (llm.agent / llm.agent_object)

startAgent ::
  RunCtx ->
  StepMode ->
  Machine ->
  [(Maybe Ident, Value)] ->
  Maybe Aeson.Value ->
  IO (Either RuntimeError StepResult)
startAgent ctx mode m args submitSchema = case parseAgentArgs args of
  Left e -> abortOrCatch ctx mode m e
  Right (system, prompt, tools, model, maxRounds, history) ->
    startAgentPrepared
      ctx
      mode
      m
      HostLlmAgent
      args
      system
      prompt
      tools
      model
      maxRounds
      submitSchema
      history

startAgentPrepared ::
  RunCtx ->
  StepMode ->
  Machine ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  Text ->
  Text ->
  [ToolSpecValue] ->
  Text ->
  Int ->
  Maybe Aeson.Value ->
  [Turn] ->
  IO (Either RuntimeError StepResult)
startAgentPrepared ctx mode m hostOp args system prompt tools model maxRounds submitSchema history = do
  sid <-
    openSpan
      ctx.rcStore
      ctx.rcSpans
      (hostOpName hostOp)
      SkHost
      (hostOpenAttrs hostOp args)
  let ag = initAgentState system prompt tools model maxRounds sid submitSchema history
      m' = pauseIfStep mode (m {mCurrent = CurAgent ag})
  _ <- persist ctx (Just hostOp) Nothing m'.mStatus (Just m')
  pure (Right (StepResult m' True))

agentHostOp :: AgentState -> HostOpId
agentHostOp ag = case ag.agSubmitSchema of
  Just _ -> HostLlmAgentObject
  Nothing -> HostLlmAgent

stepAgent ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  IO (Either RuntimeError StepResult)
stepAgent ctx mode m ag = case ag.agToolRound of
  Nothing -> stepAgentModel ctx mode m ag
  Just tr -> stepAgentTool ctx mode m ag tr

stepAgentModel ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  IO (Either RuntimeError StepResult)
stepAgentModel ctx mode m ag
  | ag.agRound >= ag.agMaxRounds = do
      let req =
            AgentExhaustedRequest
              { aerRoundsUsed = ag.agRound,
                aerRoundsBudget = ag.agMaxRounds,
                aerSuggestedExtra = suggestExtraRounds ag.agMaxRounds
              }
          m' = m {mStatus = MsPaused (PauseAwaitingAgent req), mCurrent = CurAgent ag}
      _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
      pure (Right (StepResult m' True))
  | otherwise = do
      roundSid <-
        openSpan
          ctx.rcStore
          ctx.rcSpans
          ("agent_round:" <> T.pack (show ag.agRound))
          SkAgentRound
          ( object
              [ "round" .= ag.agRound,
                "model" .= ag.agModel,
                "active_tools" .= map (.tvsName) ag.agTools,
                "loaded_instructions" .= ag.agLoadedInstructionIds
              ]
          )
      let ag' = ag {agRoundSpanId = Just roundSid}
          req0 =
            (emptyChatRequest ag.agModel)
              { chatSystem = Just (agentSystemPrompt ctx ag),
                chatTurns = ag.agHistory,
                chatTools = providerToolSpecs ag.agTools
              }
      sink <- newStreamSink ctx.rcStore ctx.rcSpans
      let req = req0 {chatOnChunk = Just sink.ssOnChunk}
      ctx.rcHost.heLog
        ( hostOpName (agentHostOp ag)
            <> " model round="
            <> T.pack (show ag.agRound)
        )
      result <- ctx.rcHost.heProvider.llmChat req
      sink.ssFlush
      case result of
        Left pe -> do
          closeSpan ctx.rcStore ctx.rcSpans roundSid SsError (object ["error" .= renderProviderError pe]) Nothing
          failAgent ctx mode m ag' (ProviderErr (renderProviderError pe))
        Right pr
          | null pr.prToolCalls -> finishAgentText ctx mode m ag' pr
          | otherwise -> do
              let roundAttrs =
                    providerRoundCloseAttrs ctx.rcHost.hePricing ag.agModel pr
              -- Keep agent_round open so tool spans nest under it.
              appendEvent
                ctx.rcStore
                ctx.rcSpans
                "debug"
                "agent_round_model"
                roundAttrs
              let tr =
                    ToolRound
                      { trPending = pr.prToolCalls,
                        trCompleted = [],
                        trActiveCall = Nothing,
                        trActiveMachine = Nothing,
                        trActiveSpanId = Nothing
                      }
                  ag'' =
                    ag'
                      { agHistory =
                          ag.agHistory
                            <> [TurnAssistant pr.prContent pr.prToolCalls],
                        agToolRound = Just tr,
                        agRoundCloseAttrs = Just roundAttrs
                      }
                  m' = pauseIfStep mode (m {mCurrent = CurAgent ag''})
              _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
              pure (Right (StepResult m' True))

finishAgentText ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ProviderResult ->
  IO (Either RuntimeError StepResult)
finishAgentText ctx mode m ag pr = case ag.agSubmitSchema of
  Just _ -> do
    mapM_
      ( \sid ->
          closeSpan
            ctx.rcStore
            ctx.rcSpans
            sid
            SsError
            (object ["error" .= ("submit required" :: Text)])
            Nothing
      )
      ag.agRoundSpanId
    failAgent
      ctx
      mode
      m
      ag
      ( ProviderErr
          "agent finished with plain text but this step requires a terminating submit call"
      )
  Nothing -> do
    mapM_
      ( \sid ->
          closeSpan
            ctx.rcStore
            ctx.rcSpans
            sid
            SsOk
            (providerRoundCloseAttrs ctx.rcHost.hePricing ag.agModel pr)
            Nothing
      )
      ag.agRoundSpanId
    let finalHistory = ag.agHistory <> [TurnAssistant pr.prContent []]
        result =
          VRecord
            [ (Ident "text", VString pr.prContent),
              (Ident "rounds", VInt (fromIntegral (ag.agRound + 1))),
              (Ident "history", turnsToValue finalHistory)
            ]
    closeSpan
      ctx.rcStore
      ctx.rcSpans
      ag.agSpanId
      SsOk
      ( object
          [ "rounds" .= (ag.agRound + 1),
            "reply_len" .= T.length pr.prContent
          ]
      )
      Nothing
    let m' = pauseIfStep mode (m {mCurrent = CurReturn result})
    _ <- persist ctx (Just HostLlmAgent) (Just result) m'.mStatus (Just m')
    pure (Right (StepResult m' True))

stepAgentTool ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  IO (Either RuntimeError StepResult)
stepAgentTool ctx mode m ag tr
  | mixesSubmit ag tr.trPending
      && isNothing tr.trActiveCall
      && isNothing tr.trActiveMachine =
      handleMixedSubmit ctx mode m ag tr
  | otherwise = case tr.trActiveMachine of
      Just (BranchMachine bm0) -> do
        let bm = case bm0.mStatus of
              MsPaused PauseExplicit -> bm0 {mStatus = MsRunning}
              _ -> bm0 {mStatus = MsRunning}
        er <- stepMachine (nestedCtx ctx) StepOnce bm
        case er of
          Left e -> recoverableTool ctx mode m ag tr e
          Right sr ->
            let bm' = sr.srMachine
             in case bm'.mStatus of
                  MsCompleted ->
                    let v = fromMaybe VUnit bm'.mLastResult
                     in completeToolCall ctx mode m ag tr (valueToJsonText v)
                  MsFailed ->
                    recoverableTool
                      ctx
                      mode
                      m
                      ag
                      tr
                      (fromMaybe (EvalErr (Trap "tool failed")) bm'.mError)
                  MsPaused (PauseAwaitingConfirm _) -> do
                    let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                        ag' = ag {agToolRound = Just tr'}
                        m' =
                          m
                            { mStatus = MsPaused (PauseAwaitingConfirm (confirmOf bm')),
                              mCurrent = CurAgent ag'
                            }
                    _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
                    pure (Right (StepResult m' True))
                  MsPaused (PauseAwaitingChoice _) -> do
                    let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                        ag' = ag {agToolRound = Just tr'}
                        m' =
                          m
                            { mStatus = MsPaused (PauseAwaitingChoice (choiceOf bm')),
                              mCurrent = CurAgent ag'
                            }
                    _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
                    pure (Right (StepResult m' True))
                  MsPaused (PauseAwaitingAsk _) -> do
                    let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                        ag' = ag {agToolRound = Just tr'}
                        m' =
                          m
                            { mStatus = MsPaused (PauseAwaitingAsk (askOf bm')),
                              mCurrent = CurAgent ag'
                            }
                    _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
                    pure (Right (StepResult m' True))
                  MsPaused PauseExplicit -> do
                    let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                        ag' = ag {agToolRound = Just tr'}
                        m' = pauseIfStep mode (m {mCurrent = CurAgent ag'})
                    _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
                    pure (Right (StepResult m' True))
                  _ ->
                    if sr.srTransitioned
                      then do
                        let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                            ag' = ag {agToolRound = Just tr'}
                            m' = pauseIfStep mode (m {mCurrent = CurAgent ag'})
                        _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
                        pure (Right (StepResult m' True))
                      else
                        pure (Left (EvalErr (Trap "agent tool machine made no progress")))
      Nothing -> case tr.trPending of
        [] -> finishToolRound ctx mode m ag tr
        tc : rest -> startToolCall ctx mode m ag (tr {trPending = rest}) tc

handleMixedSubmit ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  IO (Either RuntimeError StepResult)
handleMixedSubmit ctx mode m ag tr = do
  let msg =
        "submit must be called on its own; no tools were run this round — call submit alone"
      results =
        [ ToolResult tc.tcId tc.tcName msg
          | tc <- tr.trPending
        ]
      tr' =
        tr
          { trPending = [],
            trCompleted = results,
            trActiveCall = Nothing,
            trActiveMachine = Nothing,
            trActiveSpanId = Nothing
          }
  finishToolRound ctx mode m ag tr'

confirmOf :: Machine -> ConfirmRequest
confirmOf bm = case bm.mCurrent of
  CurAwaitConfirm c -> c
  _ -> ConfirmRequest "confirm" "" Nothing

choiceOf :: Machine -> ChoiceRequest
choiceOf bm = case bm.mCurrent of
  CurAwaitChoice c -> c
  _ -> ChoiceRequest "choice" "" [] Nothing

askOf :: Machine -> AskRequest
askOf bm = case bm.mCurrent of
  CurAwaitAsk a -> a
  _ -> AskRequest "ask" "" Nothing

startToolCall ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  ToolCall ->
  IO (Either RuntimeError StepResult)
startToolCall ctx mode m ag tr tc = do
  sid <-
    openSpan
      ctx.rcStore
      ctx.rcSpans
      ("tool:" <> tc.tcName)
      SkAgentTool
      (toolCallOpenAttrs tc)
  let tr0 =
        tr
          { trActiveCall = Just tc,
            trActiveSpanId = Just sid
          }
  if isSubmitCall tc
    then runSubmit ctx mode m ag tr0 tc
    else
      if tc.tcName == "skill_load"
        then runSkillLoadTool ctx mode m ag tr0 tc
        else case lookupTool ag.agTools tc.tcName of
          Nothing ->
            completeToolCall
              ctx
              mode
              m
              ag
              tr0
              ("unknown tool '" <> tc.tcName <> "'")
          Just tool -> case coerceToolArgs tool tc.tcArguments of
            Left reason ->
              completeToolCall
                ctx
                mode
                m
                ag
                tr0
                ("invalid arguments: " <> reason)
            Right argv -> case openApply ctx tool.tvsCallee argv of
              Left e ->
                completeToolCall
                  ctx
                  mode
                  m
                  ag
                  tr0
                  ("tool open failed: " <> renderErr e)
              Right current -> do
                let nested = initialMachine m.mProjectHash current
                    tr' =
                      tr0
                        { trActiveMachine = Just (mkBranch nested)
                        }
                    ag' = ag {agToolRound = Just tr'}
                    m' = m {mCurrent = CurAgent ag'}
                -- Continue into the nested machine this step.
                stepAgentTool ctx mode m' ag' tr'

runSkillLoadTool ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  ToolCall ->
  IO (Either RuntimeError StepResult)
runSkillLoadTool ctx mode m ag tr tc =
  case coerceToolArgs skillLoadToolSpec tc.tcArguments of
    Left reason ->
      completeToolCall ctx mode m ag tr ("invalid arguments: " <> reason)
    Right argv -> case lookup (Just (Ident "id")) argv of
      Just (VString skillId) -> do
        let load =
              agentLoadSkill
                ctx.rcHost.heSkillCatalog
                ag.agLoadedInstructionIds
                ag.agActiveToolIds
                ag.agInstructionChars
                skillId
            ag1 =
              ag
                { agLoadedInstructionIds = load.aslLoadedInstructionIds,
                  agActiveToolIds = load.aslLoadedCallableIds,
                  agInstructionChars = load.aslInstructionChars
                }
            ag2 = case load.aslNewCallable of
              Nothing -> ag1
              Just q ->
                case buildSkillToolFromQName ctx q of
                  Left _ -> ag1
                  Right ts ->
                    ag1 {agTools = insertSkillTool ag1.agTools ts}
        completeToolCall ctx mode m ag2 tr (valueToJsonText load.aslResult)
      _ ->
        completeToolCall ctx mode m ag tr "invalid arguments: missing id"

skillLoadToolSpec :: ToolSpecValue
skillLoadToolSpec =
  ToolSpecValue
    { tvsName = "skill_load",
      tvsDescription = "Load a skill by id",
      tvsParameters = object [],
      tvsCallee = VHostOp HostSkillLoad
    }

insertSkillTool :: [ToolSpecValue] -> ToolSpecValue -> [ToolSpecValue]
insertSkillTool tools ts =
  let (base, submit) = break ((== submitToolName) . (.tvsName)) tools
   in case submit of
        [] -> base ++ [ts]
        s : rest -> base ++ [ts] ++ (s : rest)

-- | Rebuild system prompt from base + loaded instruction ids (resume-safe).
agentSystemPrompt :: RunCtx -> AgentState -> Text
agentSystemPrompt ctx ag =
  let injections =
        [ instructionInjectionText sid body
          | sid <- ag.agLoadedInstructionIds,
            Just e <- [lookupSkillEntry (qnameFromText_ sid) ctx.rcHost.heSkillCatalog],
            Just body <- [seBody e]
        ]
   in T.intercalate "\n\n" (filter (not . T.null) (ag.agSystem : injections))

qnameFromText_ :: Text -> QName
qnameFromText_ t = qnameFromParts (T.splitOn "/" t)

buildSkillToolFromQName :: RunCtx -> QName -> Either RuntimeError ToolSpecValue
buildSkillToolFromQName ctx q = case Map.lookup q ctx.rcSkillModules of
  Nothing -> Left (HostErr ("skill module not loaded: " <> qnameToText q))
  Just loaded -> buildSkillToolSpec q loaded

buildSkillToolSpec :: QName -> LoadedModule -> Either RuntimeError ToolSpecValue
buildSkillToolSpec q loaded =
  let fm = loaded.lmFrontmatter
      schema =
        case typeToSchema preludeTypeEnv (TRecord fm.fmInputs) of
          Right v -> v
          Left _ ->
            object
              [ "type" .= Aeson.String "object",
                "properties" .= object [],
                "additionalProperties" .= False
              ]
      summary =
        case fm.fmSkill of
          Just meta -> fromMaybe ("skill " <> qnameToText q) meta.smSummary
          Nothing -> "skill " <> qnameToText q
   in Right
        ToolSpecValue
          { tvsName = sanitizeToolName (qnameToText q),
            tvsDescription = summary,
            tvsParameters = schema,
            tvsCallee = VSkillMain q
          }

runSubmit ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  ToolCall ->
  IO (Either RuntimeError StepResult)
runSubmit ctx mode m ag tr tc = case ag.agSubmitSchema of
  Nothing ->
    completeToolCall
      ctx
      mode
      m
      ag
      tr
      "submit is not available for this agent step"
  Just schema -> case validateSubmit schema tc.tcArguments of
    Left reason ->
      completeToolCall
        ctx
        mode
        m
        ag
        tr
        ("submit decode error: " <> reason)
    Right value -> finishAgentSubmit ctx mode m ag tr value

finishAgentSubmit ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  Value ->
  IO (Either RuntimeError StepResult)
finishAgentSubmit ctx mode m ag tr value = do
  mapM_
    ( \sid ->
        closeSpan
          ctx.rcStore
          ctx.rcSpans
          sid
          SsOk
          (object ["via" .= submitToolName])
          Nothing
    )
    tr.trActiveSpanId
  mapM_
    ( \sid ->
        closeSpan
          ctx.rcStore
          ctx.rcSpans
          sid
          SsOk
          (object ["via" .= submitToolName])
          Nothing
    )
    ag.agRoundSpanId
  let result =
        VRecord
          [ (Ident "value", value),
            (Ident "rounds", VInt (fromIntegral (ag.agRound + 1))),
            (Ident "history", turnsToValue ag.agHistory)
          ]
  closeSpan
    ctx.rcStore
    ctx.rcSpans
    ag.agSpanId
    SsOk
    (object ["rounds" .= (ag.agRound + 1), "via" .= submitToolName])
    Nothing
  let m' = pauseIfStep mode (m {mCurrent = CurReturn result})
  _ <- persist ctx (Just HostLlmAgentObject) (Just result) m'.mStatus (Just m')
  pure (Right (StepResult m' True))

completeToolCall ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  Text ->
  IO (Either RuntimeError StepResult)
completeToolCall ctx mode m ag tr content = case tr.trActiveCall of
  Nothing -> pure (Left (EvalErr (Trap "completeToolCall without active call")))
  Just tc -> do
    let status =
          if T.isPrefixOf "unknown tool" content
            || T.isPrefixOf "invalid arguments" content
            || T.isPrefixOf "tool open failed" content
            || T.isPrefixOf "tool error" content
            || content == "submit is not available for this agent step"
            || T.isPrefixOf "submit decode error" content
            then SsError
            else SsOk
    mapM_
      ( \sid ->
          closeSpan
            ctx.rcStore
            ctx.rcSpans
            sid
            status
            (object ["result_len" .= T.length content, "tool" .= tc.tcName])
            Nothing
      )
      tr.trActiveSpanId
    let result = ToolResult tc.tcId tc.tcName content
        tr' =
          tr
            { trCompleted = tr.trCompleted <> [result],
              trActiveCall = Nothing,
              trActiveMachine = Nothing,
              trActiveSpanId = Nothing
            }
    if null tr'.trPending
      then finishToolRound ctx mode m ag tr'
      else do
        let ag' = ag {agToolRound = Just tr'}
            m' = pauseIfStep mode (m {mCurrent = CurAgent ag'})
        _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
        pure (Right (StepResult m' True))

finishToolRound ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  IO (Either RuntimeError StepResult)
finishToolRound ctx mode m ag tr = do
  let roundAttrs = fromMaybe (object []) ag.agRoundCloseAttrs
      closeAttrs =
        mergeObjects
          roundAttrs
          (object ["tool_results" .= length tr.trCompleted])
  mapM_
    ( \sid ->
        closeSpan
          ctx.rcStore
          ctx.rcSpans
          sid
          SsOk
          closeAttrs
          Nothing
    )
    ag.agRoundSpanId
  let ag' =
        ag
          { agHistory = ag.agHistory <> [TurnTool tr.trCompleted],
            agRound = ag.agRound + 1,
            agToolRound = Nothing,
            agRoundSpanId = Nothing,
            agRoundCloseAttrs = Nothing
          }
      m' = pauseIfStep mode (m {mCurrent = CurAgent ag'})
  _ <- persist ctx (Just (agentHostOp ag)) Nothing m'.mStatus (Just m')
  pure (Right (StepResult m' True))

recoverableTool ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  ToolRound ->
  RuntimeError ->
  IO (Either RuntimeError StepResult)
recoverableTool ctx mode m ag tr err =
  completeToolCall ctx mode m ag tr ("tool error: " <> renderErr err)

failAgent ::
  RunCtx ->
  StepMode ->
  Machine ->
  AgentState ->
  RuntimeError ->
  IO (Either RuntimeError StepResult)
failAgent ctx mode m ag err = do
  case ag.agToolRound of
    Just tr ->
      mapM_
        ( \sid ->
            closeSpan ctx.rcStore ctx.rcSpans sid SsError (object ["error" .= renderErr err]) Nothing
        )
        tr.trActiveSpanId
    Nothing -> pure ()
  mapM_
    ( \sid ->
        closeSpan ctx.rcStore ctx.rcSpans sid SsError (object ["error" .= renderErr err]) Nothing
    )
    ag.agRoundSpanId
  closeSpan
    ctx.rcStore
    ctx.rcSpans
    ag.agSpanId
    SsError
    (object ["error" .= renderErr err])
    Nothing
  abortOrCatch ctx mode m err >>= \case
    Right sr -> do
      _ <- persist ctx (Just (agentHostOp ag)) Nothing sr.srMachine.mStatus (Just sr.srMachine)
      pure (Right sr)
    Left _ -> do
      let m' = m {mStatus = MsFailed, mError = Just err}
      _ <- persist ctx (Just (agentHostOp ag)) Nothing MsFailed (Just m')
      pure (Left err)

mergeObjects :: Aeson.Value -> Aeson.Value -> Aeson.Value
mergeObjects a b = case (a, b) of
  (Aeson.Object ka, Aeson.Object kb) -> Aeson.Object (KM.union kb ka)
  _ -> b

-------------------------------------------------------------------------------
-- Entry module invoke (E11 / FrInvoke)

-- | Enter a same-project nested module call: open span, create BranchMachine,
-- push 'FrInvoke', set 'CurInvoke'.
doEntryInvoke ::
  RunCtx ->
  StepMode ->
  Machine ->
  QName ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError StepResult)
doEntryInvoke ctx mode m q argv =
  case Map.lookup q ctx.rcEntryModules of
    Nothing ->
      abortOrCatch ctx mode m (HostErr ("entry module not loaded: " <> qnameToText q))
    Just (calleeEnv, calleeFuns) ->
      case Map.lookup (Ident "main") calleeFuns of
        Nothing ->
          abortOrCatch ctx mode m (HostErr ("entry module missing main: " <> qnameToText q))
        Just (params, body) ->
          case bindParams params argv of
            Left e -> abortOrCatch ctx mode m (EvalErr e)
            Right binds -> do
              let spanName = "module:" <> qnameToText q
              sid <-
                openSpan
                  ctx.rcStore
                  ctx.rcSpans
                  spanName
                  SkModule
                  (object [])
              let nested =
                    initialMachine
                      m.mProjectHash
                      (CurEval body (extendEnvMany binds calleeEnv))
                  m' =
                    pauseIfStep
                      mode
                      m
                        { mCurrent = CurInvoke,
                          mFrames = FrInvoke q sid (mkBranch nested) : m.mFrames
                        }
              _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
              pure (Right (StepResult m' True))

-- | Step the 'BranchMachine' held in the top 'FrInvoke' frame.
stepInvoke ::
  RunCtx -> StepMode -> Machine -> IO (Either RuntimeError StepResult)
stepInvoke ctx mode m = case m.mFrames of
  FrInvoke q sid (BranchMachine bm0) : rest -> do
    let bm = case bm0.mStatus of
          MsPaused PauseExplicit -> bm0 {mStatus = MsRunning}
          _ -> bm0
    er <- stepMachine (nestedCtx ctx) StepOnce bm
    case er of
      Left e -> abortOrCatch ctx mode m e
      Right sr ->
        let bm' = sr.srMachine
         in case bm'.mStatus of
              MsCompleted -> do
                let result = fromMaybe VUnit bm'.mLastResult
                closeSpan ctx.rcStore ctx.rcSpans sid SsOk (object []) Nothing
                let m' = pauseIfStep mode (m {mCurrent = CurReturn result, mFrames = rest})
                _ <- persist ctx Nothing (Just result) m'.mStatus (Just m')
                pure (Right (StepResult m' True))
              MsFailed -> do
                let err = fromMaybe (EvalErr (Trap "entry invoke failed")) bm'.mError
                closeSpan ctx.rcStore ctx.rcSpans sid SsError (object ["error" .= renderErr err]) Nothing
                abortOrCatch ctx mode (m {mFrames = rest}) err
              MsPaused (PauseAwaitingConfirm c) -> do
                let m' =
                      m
                        { mStatus = MsPaused (PauseAwaitingConfirm c),
                          mCurrent = CurAwaitConfirm c,
                          mFrames = FrInvoke q sid (mkBranch bm') : rest
                        }
                _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
                pure (Right (StepResult m' True))
              MsPaused (PauseAwaitingChoice c) -> do
                let m' =
                      m
                        { mStatus = MsPaused (PauseAwaitingChoice c),
                          mCurrent = CurAwaitChoice c,
                          mFrames = FrInvoke q sid (mkBranch bm') : rest
                        }
                _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
                pure (Right (StepResult m' True))
              MsPaused (PauseAwaitingAsk a) -> do
                let m' =
                      m
                        { mStatus = MsPaused (PauseAwaitingAsk a),
                          mCurrent = CurAwaitAsk a,
                          mFrames = FrInvoke q sid (mkBranch bm') : rest
                        }
                _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
                pure (Right (StepResult m' True))
              MsPaused PauseExplicit -> do
                let m' = pauseIfStep mode (m {mFrames = FrInvoke q sid (mkBranch bm') : rest})
                _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
                pure (Right (StepResult m' True))
              _ ->
                if sr.srTransitioned
                  then do
                    let m' =
                          pauseIfStep
                            mode
                            m {mCurrent = CurInvoke, mFrames = FrInvoke q sid (mkBranch bm') : rest}
                    _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
                    pure (Right (StepResult m' True))
                  else
                    pure (Left (EvalErr (Trap ("entry invoke machine made no progress: " <> qnameToText q))))
  _ -> pure (Left (EvalErr (Trap "CurInvoke without FrInvoke")))

doObsLog ::
  RunCtx -> StepMode -> Machine -> [(Maybe Ident, Value)] -> IO (Either RuntimeError StepResult)
doObsLog ctx mode m args = case parseObsLog args of
  Left e -> abortOrCatch ctx mode m e
  Right (level, message, fields) -> do
    sid <-
      openSpan
        ctx.rcStore
        ctx.rcSpans
        "obs.log"
        SkHost
        (hostOpenAttrs HostObsLog args)
    appendEvent ctx.rcStore ctx.rcSpans level message fields
    closeSpan ctx.rcStore ctx.rcSpans sid SsOk (object []) Nothing
    let m' = pauseIfStep mode (m {mCurrent = CurReturn VUnit})
    -- Observability only: spans/events, no machine snapshot (spec §05 / §07).
    pure (Right (StepResult m' False))

doObsSpan ::
  RunCtx -> StepMode -> Machine -> [(Maybe Ident, Value)] -> IO (Either RuntimeError StepResult)
doObsSpan ctx mode m args = case parseObsSpan args of
  Left e -> abortOrCatch ctx mode m e
  Right (name, thunk) -> do
    sid <-
      openSpan
        ctx.rcStore
        ctx.rcSpans
        name
        SkRegion
        (hostOpenAttrs HostObsSpan args)
    case openApply ctx thunk [] of
      Left e -> do
        closeSpan ctx.rcStore ctx.rcSpans sid SsError (object ["error" .= renderErr e]) Nothing
        abortOrCatch ctx mode m e
      Right current -> do
        let m' =
              m
                { mCurrent = current,
                  mFrames = FrRegion sid : m.mFrames
                }
        -- Region open itself is not a host snapshot boundary; body host ops will snap.
        pure (Right (StepResult (pauseIfStep mode m') False))

parseObsLog :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Text, Aeson.Value)
parseObsLog args = do
  level <- case lookup (Just (Ident "level")) args of
    Just (VString t) -> Right t
    _ -> case [v | (Nothing, v) <- args] of
      (VString t : _) -> Right t
      _ -> Left (HostErr "obs.log expects level: String")
  message <- case lookup (Just (Ident "message")) args of
    Just (VString t) -> Right t
    _ -> case [v | (Nothing, v) <- args] of
      (_ : VString t : _) -> Right t
      _ -> Left (HostErr "obs.log expects message: String")
  let fields = case lookup (Just (Ident "fields")) args of
        Just (VRecord fs) ->
          object [Key.fromText (unIdent k) .= fieldJson v | (k, v) <- fs]
        _ -> object []
  pure (level, message, fields)
  where
    fieldJson = \case
      VString t -> Aeson.String t
      VInt n -> Aeson.Number (fromIntegral n)
      VBool b -> Aeson.Bool b
      VSecret _ -> Aeson.String "[REDACTED]"
      _ -> Aeson.Null

parseObsSpan :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Value)
parseObsSpan args = case (obsSpanNameArg args, obsSpanBodyArg args) of
  (Just (VString name), Just thunk)
    | isObsSpanThunk thunk -> Right (name, thunk)
    | otherwise -> Left (HostErr "obs.span body must be a function")
  _ -> Left (HostErr "obs.span expects name: String and a thunk")

-- | True when @obs.span@ has a name but not yet a body (curried first app).
obsSpanNeedsBody :: [(Maybe Ident, Value)] -> Bool
obsSpanNeedsBody args =
  isJust (obsSpanNameArg args) && isNothing (obsSpanBodyArg args)

obsSpanNameArg :: [(Maybe Ident, Value)] -> Maybe Value
obsSpanNameArg args =
  lookup (Just (Ident "name")) args
    <|> case [v | (Nothing, v) <- args] of
      (v : _) -> Just v
      [] -> Nothing
  where
    (<|>) :: Maybe a -> Maybe a -> Maybe a
    (<|>) (Just x) _ = Just x
    (<|>) Nothing y = y

obsSpanBodyArg :: [(Maybe Ident, Value)] -> Maybe Value
obsSpanBodyArg args =
  lookup (Just (Ident "body")) args
    <|> case [v | (Nothing, v) <- args] of
      (_ : v : _) -> Just v
      _ -> Nothing
  where
    (<|>) :: Maybe a -> Maybe a -> Maybe a
    (<|>) (Just x) _ = Just x
    (<|>) Nothing y = y

isObsSpanThunk :: Value -> Bool
isObsSpanThunk = \case
  VClosure {} -> True
  VTopFun {} -> True
  _ -> False

pauseIfStep :: StepMode -> Machine -> Machine
pauseIfStep StepOnce m
  | m.mStatus == MsRunning = m {mStatus = MsPaused PauseExplicit}
  | otherwise = m
pauseIfStep StepRun m = m

-------------------------------------------------------------------------------
-- Approve / choose

approveMachine :: Bool -> Machine -> Either RuntimeError Machine
approveMachine yes m = case m.mStatus of
  MsPaused (PauseAwaitingConfirm c) ->
    case (m.mFrames, m.mCurrent) of
      (FrPar pjs : rest, _) -> Right (approvePar yes c pjs rest m)
      (FrAfterConfirm next : rest, _) ->
        if yes
          then
            Right
              m
                { mStatus = MsRunning,
                  mCurrent = next,
                  mFrames = FrExecApproved : rest
                }
          else
            Right
              m
                { mStatus = MsFailed,
                  mError = Just (HostErr "exec.run denied by operator"),
                  mCurrent = CurReturn VUnit,
                  mFrames = rest
                }
      (FrConfirm _ : rest, _) ->
        Right
          m
            { mStatus = MsRunning,
              mCurrent = CurReturn (VBool yes),
              mFrames = rest
            }
      (_, CurAgent ag)
        | Just tr <- ag.agToolRound,
          Just (BranchMachine bm) <- tr.trActiveMachine ->
            case approveMachine yes bm of
              Left e -> Left e
              Right bm' ->
                let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                    ag' = ag {agToolRound = Just tr'}
                 in Right
                      m
                        { mStatus = MsRunning,
                          mCurrent = CurAgent ag'
                        }
      (FrInvoke q sid (BranchMachine bm) : rest, _) ->
        case approveMachine yes bm of
          Left e -> Left e
          Right bm' ->
            Right
              m
                { mStatus = MsRunning,
                  mCurrent = CurInvoke,
                  mFrames = FrInvoke q sid (mkBranch bm') : rest
                }
      _ ->
        Right
          m
            { mStatus = MsRunning,
              mCurrent = CurReturn (VBool yes)
            }
  _ -> Left (ConfigErr "run is not awaiting confirmation")

chooseMachine :: Text -> Machine -> Either RuntimeError Machine
chooseMachine selected m = case m.mStatus of
  MsPaused (PauseAwaitingChoice c) ->
    if selected `notElem` c.chOptions
      then
        Left
          ( ConfigErr
              ( "choice "
                  <> selected
                  <> " is not one of: "
                  <> T.intercalate ", " c.chOptions
              )
          )
      else case (m.mFrames, m.mCurrent) of
        (FrPar pjs : rest, _) -> Right (choosePar selected c pjs rest m)
        (FrChoice _ : rest, _) ->
          Right
            m
              { mStatus = MsRunning,
                mCurrent = CurReturn (VString selected),
                mFrames = rest
              }
        (_, CurAgent ag)
          | Just tr <- ag.agToolRound,
            Just (BranchMachine bm) <- tr.trActiveMachine ->
              case chooseMachine selected bm of
                Left e -> Left e
                Right bm' ->
                  let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                      ag' = ag {agToolRound = Just tr'}
                   in Right
                        m
                          { mStatus = MsRunning,
                            mCurrent = CurAgent ag'
                          }
        (FrInvoke q sid (BranchMachine bm) : rest, _) ->
          case chooseMachine selected bm of
            Left e -> Left e
            Right bm' ->
              Right
                m
                  { mStatus = MsRunning,
                    mCurrent = CurInvoke,
                    mFrames = FrInvoke q sid (mkBranch bm') : rest
                  }
        _ ->
          Right
            m
              { mStatus = MsRunning,
                mCurrent = CurReturn (VString selected)
              }
  _ -> Left (ConfigErr "run is not awaiting a choice")

replyMachine :: Text -> Machine -> Either RuntimeError Machine
replyMachine text m = case m.mStatus of
  MsPaused (PauseAwaitingAsk a) ->
    case (m.mFrames, m.mCurrent) of
      (FrPar pjs : rest, _) -> Right (replyPar text a pjs rest m)
      (FrAsk _ : rest, _) ->
        Right
          m
            { mStatus = MsRunning,
              mCurrent = CurReturn (VString text),
              mFrames = rest
            }
      (_, CurAgent ag)
        | Just tr <- ag.agToolRound,
          Just (BranchMachine bm) <- tr.trActiveMachine ->
            case replyMachine text bm of
              Left e -> Left e
              Right bm' ->
                let tr' = tr {trActiveMachine = Just (mkBranch bm')}
                    ag' = ag {agToolRound = Just tr'}
                 in Right
                      m
                        { mStatus = MsRunning,
                          mCurrent = CurAgent ag'
                        }
      (FrInvoke q sid (BranchMachine bm) : rest, _) ->
        case replyMachine text bm of
          Left e -> Left e
          Right bm' ->
            Right
              m
                { mStatus = MsRunning,
                  mCurrent = CurInvoke,
                  mFrames = FrInvoke q sid (mkBranch bm') : rest
                }
      _ ->
        Right
          m
            { mStatus = MsRunning,
              mCurrent = CurReturn (VString text)
            }
  _ -> Left (ConfigErr "run is not awaiting input")

-- | Round up to the nearest power of two ≥ 1 (used for exhausted-budget hint).
suggestExtraRounds :: Int -> Int
suggestExtraRounds budget = max 1 (nextPow2 budget)
  where
    nextPow2 n = head [p | p <- map (2 ^) [(0 :: Int) ..], p >= n]

-- | Bump @agMaxRounds@ by @extraRounds@ and resume from an exhausted-budget pause.
extendAgentMachine :: Int -> Machine -> Either RuntimeError Machine
extendAgentMachine extra m = case m.mStatus of
  MsPaused (PauseAwaitingAgent _) -> case m.mCurrent of
    CurAgent ag ->
      Right
        m
          { mStatus = MsRunning,
            mCurrent = CurAgent ag {agMaxRounds = ag.agMaxRounds + extra}
          }
    _ -> Left (ConfigErr "run is not awaiting agent budget extension")
  _ -> Left (ConfigErr "run is not awaiting agent budget extension")

approvePar :: Bool -> ConfirmRequest -> ParJoinState -> [Frame] -> Machine -> Machine
approvePar yes c pjs rest m =
  let idx = fromMaybe 0 c.crBranchIndex
      pjs' =
        pjs
          { pjsPhase = ParScheduling,
            pjsConfirmQueue = drop 1 pjs.pjsConfirmQueue,
            pjsSlots = setSlot idx ParSlotRunning pjs.pjsSlots,
            pjsActive =
              Map.adjust
                ( \(BranchMachine bm) ->
                    mkBranch
                      bm
                        { mStatus = MsRunning,
                          mCurrent = CurReturn (VBool yes),
                          mFrames = dropConfirmFrame bm.mFrames
                        }
                )
                idx
                pjs.pjsActive
          }
   in m
        { mStatus = MsRunning,
          mCurrent = CurParPool,
          mFrames = FrPar pjs' : rest
        }

choosePar :: Text -> ChoiceRequest -> ParJoinState -> [Frame] -> Machine -> Machine
choosePar selected c pjs rest m =
  let idx = fromMaybe 0 c.chBranchIndex
      pjs' =
        pjs
          { pjsPhase = ParScheduling,
            pjsChoiceQueue = drop 1 pjs.pjsChoiceQueue,
            pjsSlots = setSlot idx ParSlotRunning pjs.pjsSlots,
            pjsActive =
              Map.adjust
                ( \(BranchMachine bm) ->
                    mkBranch
                      bm
                        { mStatus = MsRunning,
                          mCurrent = CurReturn (VString selected),
                          mFrames = dropChoiceFrame bm.mFrames
                        }
                )
                idx
                pjs.pjsActive
          }
   in m
        { mStatus = MsRunning,
          mCurrent = CurParPool,
          mFrames = FrPar pjs' : rest
        }

replyPar :: Text -> AskRequest -> ParJoinState -> [Frame] -> Machine -> Machine
replyPar text a pjs rest m =
  let idx = fromMaybe 0 a.askBranchIndex
      pjs' =
        pjs
          { pjsPhase = ParScheduling,
            pjsAskQueue = drop 1 pjs.pjsAskQueue,
            pjsSlots = setSlot idx ParSlotRunning pjs.pjsSlots,
            pjsActive =
              Map.adjust
                ( \(BranchMachine bm) ->
                    mkBranch
                      bm
                        { mStatus = MsRunning,
                          mCurrent = CurReturn (VString text),
                          mFrames = dropAskFrame bm.mFrames
                        }
                )
                idx
                pjs.pjsActive
          }
   in m
        { mStatus = MsRunning,
          mCurrent = CurParPool,
          mFrames = FrPar pjs' : rest
        }

dropConfirmFrame :: [Frame] -> [Frame]
dropConfirmFrame = \case
  FrConfirm _ : rest -> rest
  frames -> frames

dropChoiceFrame :: [Frame] -> [Frame]
dropChoiceFrame = \case
  FrChoice _ : rest -> rest
  frames -> frames

dropAskFrame :: [Frame] -> [Frame]
dropAskFrame = \case
  FrAsk _ : rest -> rest
  frames -> frames

-------------------------------------------------------------------------------
-- Par

stepPar :: RunCtx -> StepMode -> Machine -> IO (Either RuntimeError StepResult)
stepPar ctx mode m = case m.mFrames of
  FrPar pjs : rest -> stepParWith ctx mode m pjs rest
  _ -> pure (Left (EvalErr (Trap "CurParPool without FrPar")))

stepParWith ::
  RunCtx ->
  StepMode ->
  Machine ->
  ParJoinState ->
  [Frame] ->
  IO (Either RuntimeError StepResult)
stepParWith ctx mode m pjs rest
  | pjs.pjsPhase == ParPausedConfirm = pure (Right (StepResult m False))
  | canSpawn pjs = do
      let idx = pjs.pjsNextIndex
          item = pjs.pjsItems !! idx
          branchEnv = extendEnv pjs.pjsVar item pjs.pjsParentEnv
          branch = initialMachine m.mProjectHash (CurEval pjs.pjsBody branchEnv)
          pjs' =
            pjs
              { pjsNextIndex = idx + 1,
                pjsSlots = setSlot idx ParSlotRunning pjs.pjsSlots,
                pjsActive = Map.insert idx (mkBranch branch) pjs.pjsActive
              }
          m' = m {mCurrent = CurParPool, mFrames = FrPar pjs' : rest}
      finishParStep ctx mode m' True
  | Just idx <- pickRunnable pjs = do
      let BranchMachine bm0 = pjs.pjsActive Map.! idx
          bm = case bm0.mStatus of
            MsPaused PauseExplicit -> bm0 {mStatus = MsRunning}
            _ -> bm0 {mStatus = MsRunning}
      er <- stepMachine (nestedCtx ctx) StepOnce bm
      case er of
        Left e ->
          handleAfterBranch ctx mode m (absorbFailed pjs idx (renderErr e)) rest
        Right sr ->
          let bm' = sr.srMachine
           in case bm'.mStatus of
                MsCompleted ->
                  handleAfterBranch
                    ctx
                    mode
                    m
                    (absorbDone pjs idx (fromMaybe VUnit bm'.mLastResult))
                    rest
                MsFailed ->
                  handleAfterBranch
                    ctx
                    mode
                    m
                    (absorbFailed pjs idx (maybe "branch failed" renderErr bm'.mError))
                    rest
                MsPaused (PauseAwaitingConfirm c) ->
                  let c' = c {crBranchIndex = Just idx}
                      pjs' = absorbConfirm pjs idx bm' c'
                      m' =
                        m
                          { mStatus = MsDraining,
                            mCurrent = CurParPool,
                            mFrames = FrPar pjs' : rest
                          }
                   in tryFinishDrain ctx mode m' pjs' rest
                MsPaused (PauseAwaitingChoice c) ->
                  let c' = c {chBranchIndex = Just idx}
                      pjs' = absorbChoice pjs idx bm' c'
                      m' =
                        m
                          { mStatus = MsDraining,
                            mCurrent = CurParPool,
                            mFrames = FrPar pjs' : rest
                          }
                   in tryFinishDrain ctx mode m' pjs' rest
                MsPaused (PauseAwaitingAsk a) ->
                  let a' = a {askBranchIndex = Just idx}
                      pjs' = absorbAsk pjs idx bm' a'
                      m' =
                        m
                          { mStatus = MsDraining,
                            mCurrent = CurParPool,
                            mFrames = FrPar pjs' : rest
                          }
                   in tryFinishDrain ctx mode m' pjs' rest
                MsPaused PauseExplicit -> do
                  let pjs' = pjs {pjsActive = Map.insert idx (mkBranch bm') pjs.pjsActive}
                      m' = m {mCurrent = CurParPool, mFrames = FrPar pjs' : rest}
                  finishParStep ctx mode m' True
                _ -> do
                  let pjs' = pjs {pjsActive = Map.insert idx (mkBranch bm') pjs.pjsActive}
                      m' = m {mCurrent = CurParPool, mFrames = FrPar pjs' : rest}
                  if sr.srTransitioned
                    then finishParStep ctx mode m' True
                    else
                      pure (Left (EvalErr (Trap ("par branch " <> T.pack (show idx) <> " made no progress"))))
  | awaitingHuman pjs = tryFinishDrain ctx mode m pjs rest
  | allTerminal pjs.pjsSlots = finishJoin ctx mode m pjs rest
  | pjs.pjsPhase == ParDraining = tryFinishDrain ctx mode m pjs rest
  | otherwise = pure (Left (EvalErr (Trap "par pool stuck")))

awaitingHuman :: ParJoinState -> Bool
awaitingHuman pjs =
  not (null pjs.pjsConfirmQueue)
    || not (null pjs.pjsChoiceQueue)
    || not (null pjs.pjsAskQueue)
    || any
      ( \case
          ParSlotAwaitingConfirm _ -> True
          ParSlotAwaitingChoice _ -> True
          ParSlotAwaitingAsk _ -> True
          _ -> False
      )
      pjs.pjsSlots

pickRunnable :: ParJoinState -> Maybe Int
pickRunnable pjs =
  let runnable =
        [ i
          | (i, bm) <- Map.toList pjs.pjsActive,
            case (unBranch bm).mStatus of
              MsPaused (PauseAwaitingConfirm _) -> False
              MsPaused (PauseAwaitingChoice _) -> False
              MsPaused (PauseAwaitingAsk _) -> False
              MsCompleted -> False
              MsFailed -> False
              _ -> True
        ]
   in case runnable of
        (i : _) -> Just i
        [] -> Nothing

handleAfterBranch ::
  RunCtx ->
  StepMode ->
  Machine ->
  ParJoinState ->
  [Frame] ->
  IO (Either RuntimeError StepResult)
handleAfterBranch ctx mode m pjs rest
  | pjs.pjsPhase == ParDraining = tryFinishDrain ctx mode m pjs rest
  | allTerminal pjs.pjsSlots = finishJoin ctx mode m pjs rest
  | otherwise =
      finishParStep ctx mode m {mCurrent = CurParPool, mFrames = FrPar pjs : rest} True

tryFinishDrain ::
  RunCtx ->
  StepMode ->
  Machine ->
  ParJoinState ->
  [Frame] ->
  IO (Either RuntimeError StepResult)
tryFinishDrain ctx mode m pjs rest
  | noRunnableActive pjs =
      case confirmQueue pjs of
        (c : cs) -> do
          let pjs' = pjs {pjsPhase = ParPausedConfirm, pjsConfirmQueue = c : cs}
              m' =
                m
                  { mStatus = MsPaused (PauseAwaitingConfirm c),
                    mCurrent = CurAwaitConfirm c,
                    mFrames = FrPar pjs' : rest
                  }
          _ <-
            openSpan
              ctx.rcStore
              ctx.rcSpans
              "human.confirm"
              SkHost
              (hostOpenAttrs HostHumanConfirm [(Just (Ident "title"), VString c.crTitle)])
          _ <- persist ctx (Just HostHumanConfirm) Nothing (MsPaused (PauseAwaitingConfirm c)) (Just m')
          pure (Right (StepResult m' True))
        [] -> case choiceQueue pjs of
          (c : cs) -> do
            let pjs' = pjs {pjsPhase = ParPausedConfirm, pjsChoiceQueue = c : cs}
                m' =
                  m
                    { mStatus = MsPaused (PauseAwaitingChoice c),
                      mCurrent = CurAwaitChoice c,
                      mFrames = FrPar pjs' : rest
                    }
            _ <-
              openSpan
                ctx.rcStore
                ctx.rcSpans
                "human.choice"
                SkHost
                ( hostOpenAttrs
                    HostHumanChoice
                    [ (Just (Ident "title"), VString c.chTitle),
                      (Just (Ident "options"), VList (map VString c.chOptions))
                    ]
                )
            _ <- persist ctx (Just HostHumanChoice) Nothing (MsPaused (PauseAwaitingChoice c)) (Just m')
            pure (Right (StepResult m' True))
          [] -> case askQueue pjs of
            (a : as) -> do
              let pjs' = pjs {pjsPhase = ParPausedConfirm, pjsAskQueue = a : as}
                  m' =
                    m
                      { mStatus = MsPaused (PauseAwaitingAsk a),
                        mCurrent = CurAwaitAsk a,
                        mFrames = FrPar pjs' : rest
                      }
              _ <-
                openSpan
                  ctx.rcStore
                  ctx.rcSpans
                  "human.ask"
                  SkHost
                  (hostOpenAttrs HostHumanAsk [(Just (Ident "prompt"), VString a.askPrompt)])
              _ <- persist ctx (Just HostHumanAsk) Nothing (MsPaused (PauseAwaitingAsk a)) (Just m')
              pure (Right (StepResult m' True))
            [] -> finishJoin ctx mode m pjs rest
  | otherwise =
      finishParStep
        ctx
        mode
        m
          { mStatus = MsDraining,
            mCurrent = CurParPool,
            mFrames = FrPar pjs : rest
          }
        True

-- | Branches awaiting human input are not runnable; drain completes when none remain.
noRunnableActive :: ParJoinState -> Bool
noRunnableActive pjs =
  all
    ( \bm -> case (unBranch bm).mStatus of
        MsPaused (PauseAwaitingConfirm _) -> True
        MsPaused (PauseAwaitingChoice _) -> True
        MsPaused (PauseAwaitingAsk _) -> True
        _ -> False
    )
    (Map.elems pjs.pjsActive)

confirmQueue :: ParJoinState -> [ConfirmRequest]
confirmQueue pjs
  | not (null pjs.pjsConfirmQueue) = pjs.pjsConfirmQueue
  | otherwise =
      [ c
        | ParSlotAwaitingConfirm c <- pjs.pjsSlots
      ]

choiceQueue :: ParJoinState -> [ChoiceRequest]
choiceQueue pjs
  | not (null pjs.pjsChoiceQueue) = pjs.pjsChoiceQueue
  | otherwise =
      [ c
        | ParSlotAwaitingChoice c <- pjs.pjsSlots
      ]

askQueue :: ParJoinState -> [AskRequest]
askQueue pjs
  | not (null pjs.pjsAskQueue) = pjs.pjsAskQueue
  | otherwise =
      [ a
        | ParSlotAwaitingAsk a <- pjs.pjsSlots
      ]

finishJoin ::
  RunCtx ->
  StepMode ->
  Machine ->
  ParJoinState ->
  [Frame] ->
  IO (Either RuntimeError StepResult)
finishJoin ctx mode m pjs rest = case joinSlots pjs.pjsOnError pjs.pjsSlots of
  Left err -> do
    let m' = m {mStatus = MsFailed, mError = Just (EvalErr (Trap err)), mFrames = rest}
    _ <- persist ctx Nothing Nothing MsFailed (Just m')
    pure (Left (EvalErr (Trap err)))
  Right vs -> do
    let m' =
          pauseIfStep
            mode
            m
              { mStatus = MsRunning,
                mCurrent = CurReturn (VList vs),
                mFrames = rest
              }
    _ <- persist ctx Nothing (Just (VList vs)) m'.mStatus (Just m')
    pure (Right (StepResult m' True))

finishParStep ::
  RunCtx ->
  StepMode ->
  Machine ->
  Bool ->
  IO (Either RuntimeError StepResult)
finishParStep ctx mode m transitioned = do
  let m' = if transitioned then pauseIfStep mode m else m
  when transitioned $ do
    _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
    pure ()
  pure (Right (StepResult m' transitioned))

when :: Bool -> IO () -> IO ()
when b a = if b then a else pure ()

canSpawn :: ParJoinState -> Bool
canSpawn pjs =
  pjs.pjsPhase == ParScheduling
    && pjs.pjsNextIndex < length pjs.pjsItems
    && Map.size pjs.pjsActive < pjs.pjsMax

allTerminal :: [ParSlot] -> Bool
allTerminal = all $ \case
  ParSlotDone {} -> True
  ParSlotFailed {} -> True
  _ -> False

absorbDone :: ParJoinState -> Int -> Value -> ParJoinState
absorbDone pjs idx v =
  pjs
    { pjsSlots = setSlot idx (ParSlotDone v) pjs.pjsSlots,
      pjsActive = Map.delete idx pjs.pjsActive
    }

absorbFailed :: ParJoinState -> Int -> Text -> ParJoinState
absorbFailed pjs idx msg =
  let pjs' =
        pjs
          { pjsSlots = setSlot idx (ParSlotFailed msg) pjs.pjsSlots,
            pjsActive = Map.delete idx pjs.pjsActive
          }
   in case pjs.pjsOnError of
        ParFail -> pjs' {pjsPhase = ParDraining}
        ParCollect -> pjs'

absorbConfirm :: ParJoinState -> Int -> Machine -> ConfirmRequest -> ParJoinState
absorbConfirm pjs idx bm c =
  pjs
    { pjsSlots = setSlot idx (ParSlotAwaitingConfirm c) pjs.pjsSlots,
      pjsActive = Map.insert idx (mkBranch bm) pjs.pjsActive,
      pjsPhase = ParDraining,
      pjsConfirmQueue = pjs.pjsConfirmQueue ++ [c]
    }

absorbChoice :: ParJoinState -> Int -> Machine -> ChoiceRequest -> ParJoinState
absorbChoice pjs idx bm c =
  pjs
    { pjsSlots = setSlot idx (ParSlotAwaitingChoice c) pjs.pjsSlots,
      pjsActive = Map.insert idx (mkBranch bm) pjs.pjsActive,
      pjsPhase = ParDraining,
      pjsChoiceQueue = pjs.pjsChoiceQueue ++ [c]
    }

absorbAsk :: ParJoinState -> Int -> Machine -> AskRequest -> ParJoinState
absorbAsk pjs idx bm a =
  pjs
    { pjsSlots = setSlot idx (ParSlotAwaitingAsk a) pjs.pjsSlots,
      pjsActive = Map.insert idx (mkBranch bm) pjs.pjsActive,
      pjsPhase = ParDraining,
      pjsAskQueue = pjs.pjsAskQueue ++ [a]
    }

setSlot :: Int -> ParSlot -> [ParSlot] -> [ParSlot]
setSlot idx slot slots =
  [ if i == idx then slot else s
    | (i, s) <- zip [0 ..] slots
  ]

joinSlots :: ParOnError -> [ParSlot] -> Either Text [Value]
joinSlots ParFail slots =
  case [msg | ParSlotFailed msg <- slots] of
    (msg : _) -> Left msg
    [] -> Right [v | ParSlotDone v <- slots]
joinSlots ParCollect slots =
  Right
    [ case s of
        ParSlotDone v ->
          VRecord [(Ident "ok", VBool True), (Ident "value", v)]
        ParSlotFailed msg ->
          VRecord [(Ident "ok", VBool False), (Ident "error", VString msg)]
        _ ->
          VRecord [(Ident "ok", VBool False), (Ident "error", VString "incomplete")]
      | s <- slots
    ]

renderErr :: RuntimeError -> Text
renderErr = T.pack . show

-- | Nearest @FrTry@ on the kont stack (innermost first).
tryFrame :: [Frame] -> Maybe (Ident, Env, Expr, [Frame])
tryFrame frames =
  case break isTryFr frames of
    (_, FrTry var handlerEnv handler : after) ->
      Just (var, handlerEnv, handler, after)
    _ -> Nothing
  where
    isTryFr (FrTry {}) = True
    isTryFr _ = False

dispatchCatch :: Machine -> RuntimeError -> Maybe Machine
dispatchCatch m err
  | isCatchable err,
    Just (var, handlerEnv, handler, rest) <- tryFrame m.mFrames =
      Just
        m
          { mStatus = MsRunning,
            mError = Nothing,
            mCurrent =
              CurEval
                handler
                (extendEnv var (VString (renderRuntimeError err)) handlerEnv),
            mFrames = rest
          }
  | otherwise = Nothing

abortOrCatch ::
  RunCtx -> StepMode -> Machine -> RuntimeError -> IO (Either RuntimeError StepResult)
abortOrCatch ctx mode m err = case dispatchCatch m err of
  Nothing -> pure (Left err)
  Just caught -> do
    let m' = pauseIfStep mode caught
    _ <- persist ctx Nothing Nothing m'.mStatus (Just m')
    pure (Right (StepResult m' True))

-------------------------------------------------------------------------------
-- Pure crunch

crunch :: RunCtx -> Machine -> Either RuntimeError Machine
crunch ctx = go (0 :: Int)
  where
    go n m
      | n > 500000 = Left (EvalErr (Trap "pure crunch limit exceeded"))
      | otherwise = case crunchOnce ctx m of
          Left e -> Left e
          Right Nothing -> Right m
          Right (Just m') -> go (n + 1) m'

crunchOnce :: RunCtx -> Machine -> Either RuntimeError (Maybe Machine)
crunchOnce ctx m = case m.mStatus of
  MsRunning -> body
  MsDraining -> body
  _ -> Right Nothing
  where
    body = case m.mCurrent of
      CurHost {} -> Right Nothing
      CurAwaitConfirm {} -> Right Nothing
      CurAwaitChoice {} -> Right Nothing
      CurAwaitAsk {} -> Right Nothing
      CurParPool -> Right Nothing
      CurCloseRegion {} -> Right Nothing
      CurAgent {} -> Right Nothing
      CurEntryInvoke {} -> Right Nothing
      CurInvoke -> Right Nothing
      CurEval e env -> crunchEval ctx m e env
      CurReturn v -> crunchReturn ctx m v

crunchEval :: RunCtx -> Machine -> Expr -> Env -> Either RuntimeError (Maybe Machine)
crunchEval ctx m e env = case e of
  ELit lit -> ret m (literalValue lit)
  EVar n -> case lookupEnv n env of
    Nothing -> Left (EvalErr (Trap ("unbound variable: " <> unIdent n)))
    Just v -> ret m v
  -- Resolved at check time; elaborate to a callable entry-main value.
  EQName q -> ret m (VEntryMain q)
  ESection s -> case Map.lookup s ctx.rcSections of
    Just t -> ret m (VString t)
    Nothing -> Left (EvalErr (Trap ("unknown section: @" <> slugToText s)))
  EFun ps _ body -> ret m (VClosure ps body env)
  ESchema te -> case typeToSchemaWithDocs ctx.rcTypeEnv ctx.rcSchemaDocs te of
    Left err -> Left (EvalErr (Trap (renderCheckError err)))
    Right schema -> ret m (VSchema schema)
  ETry body errVar handler ->
    Right
      ( Just
          m
            { mCurrent = CurEval body env,
              mFrames = FrTry errVar env handler : m.mFrames
            }
      )
  EList [] -> ret m (VList [])
  EList (x : xs) ->
    Right (Just m {mCurrent = CurEval x env, mFrames = FrList [] env xs : m.mFrames})
  ERecord fs -> pushRecord m env [] fs
  EInterp parts -> pushInterp m env [] parts
  EApp f args ->
    Right (Just m {mCurrent = CurEval f env, mFrames = FrAppFun env args : m.mFrames})
  EProj e0 f ->
    Right (Just m {mCurrent = CurEval e0 env, mFrames = FrProj f : m.mFrames})
  EIndex e0 ix ->
    Right (Just m {mCurrent = CurEval e0 env, mFrames = FrIndexE env ix : m.mFrames})
  ELet n _ e1 e2 ->
    Right (Just m {mCurrent = CurEval e1 env, mFrames = FrLet n env e2 : m.mFrames})
  EIf c t el ->
    Right (Just m {mCurrent = CurEval c env, mFrames = FrIf env t el : m.mFrames})
  EMatch scrut arms ->
    Right (Just m {mCurrent = CurEval scrut env, mFrames = FrMatch env arms : m.mFrames})
  EPar opts n xs body ->
    Right
      ( Just
          m
            { mCurrent = CurEval xs env,
              mFrames = FrPar (pendingPar opts n body env) : m.mFrames
            }
      )
  EJoin [] -> Left (EvalErr (Trap "empty join"))
  EJoin (t0 : ts) ->
    Right (Just m {mCurrent = CurEval t0 env, mFrames = FrJoin [] env ts : m.mFrames})
  EConfirm e0 ->
    Right
      ( Just
          m
            { mCurrent = CurEval e0 env,
              mFrames = FrConfirm (ConfirmRequest "" "" Nothing) : m.mFrames
            }
      )
  EChoice e0 ->
    Right
      ( Just
          m
            { mCurrent = CurEval e0 env,
              mFrames = FrChoice (ChoiceRequest "" "" [] Nothing) : m.mFrames
            }
      )

ret :: Machine -> Value -> Either RuntimeError (Maybe Machine)
ret m v = Right (Just m {mCurrent = CurReturn v})

pendingPar :: [ParOpt] -> Ident -> Expr -> Env -> ParJoinState
pendingPar opts var body env =
  ParJoinState
    { pjsVar = var,
      pjsBody = body,
      pjsMax = parMaxOf opts,
      pjsOnError = parOnErrorOf opts,
      pjsItems = [],
      pjsSlots = [],
      pjsActive = Map.empty,
      pjsNextIndex = 0,
      pjsPhase = ParScheduling,
      pjsConfirmQueue = [],
      pjsChoiceQueue = [],
      pjsAskQueue = [],
      pjsParentEnv = env
    }

parMaxOf :: [ParOpt] -> Int
parMaxOf opts = case [n | ParMax n <- opts] of
  (n : _) -> max 1 (fromIntegral n)
  [] -> 4

parOnErrorOf :: [ParOpt] -> ParOnError
parOnErrorOf opts = case [e | ParOnError e <- opts] of
  ("collect" : _) -> ParCollect
  _ -> ParFail

pushRecord ::
  Machine -> Env -> [(Ident, Value)] -> [Field] -> Either RuntimeError (Maybe Machine)
pushRecord m env acc = \case
  [] -> ret m (VRecord (reverse acc))
  FieldShorthand n : fs -> case lookupEnv n env of
    Nothing -> Left (EvalErr (Trap ("unbound shorthand field: " <> unIdent n)))
    Just v -> pushRecord m env ((n, v) : acc) fs
  Field n e : fs ->
    Right
      ( Just
          m
            { mCurrent = CurEval e env,
              mFrames = FrRecord acc env (Field n e : fs) : m.mFrames
            }
      )

pushInterp ::
  Machine -> Env -> [Text] -> [StringPart] -> Either RuntimeError (Maybe Machine)
pushInterp m env acc = \case
  [] -> ret m (VString (T.concat (reverse acc)))
  SLit t : rest -> pushInterp m env (t : acc) rest
  SInterp e : rest ->
    Right
      ( Just
          m
            { mCurrent = CurEval e env,
              mFrames = FrInterp acc env (SInterp e : rest) : m.mFrames
            }
      )

crunchReturn :: RunCtx -> Machine -> Value -> Either RuntimeError (Maybe Machine)
crunchReturn ctx m v = case m.mFrames of
  [] -> Right Nothing
  fr : rest -> case fr of
    FrLet n env body ->
      Right (Just m {mCurrent = CurEval body (extendEnv n v env), mFrames = rest})
    FrAppFun env args -> applyOrArgs ctx m v [] env args rest
    FrAppArgs f collected env args ->
      -- `args` head is the Arg we just finished evaluating.
      case args of
        [] -> Left (EvalErr (Trap "FrAppArgs with empty remaining"))
        (a : as) ->
          let collected' = (argName a, v) : collected
           in applyOrArgs ctx m f collected' env as rest
    FrList acc env es -> case es of
      [] -> ret m {mFrames = rest} (VList (reverse (v : acc)))
      e : es' ->
        Right
          ( Just
              m
                { mCurrent = CurEval e env,
                  mFrames = FrList (v : acc) env es' : rest
                }
          )
    FrRecord acc env fs -> case fs of
      Field n _ : fs' -> pushRecord m {mFrames = rest} env ((n, v) : acc) fs'
      _ -> Left (EvalErr (Trap "FrRecord invariant"))
    FrInterp acc env parts -> case parts of
      SInterp _ : restParts -> case renderValue v of
        Left msg -> Left (EvalErr (Trap msg))
        Right t -> pushInterp m {mFrames = rest} env (t : acc) restParts
      _ -> Left (EvalErr (Trap "FrInterp invariant"))
    FrProj f -> case project v f of
      Left e -> Left (EvalErr e)
      Right v' -> ret m {mFrames = rest} v'
    FrIndexE env ix ->
      Right (Just m {mCurrent = CurEval ix env, mFrames = FrIndexV v : rest})
    FrIndexV lst -> case indexList lst v of
      Left e -> Left (EvalErr e)
      Right v' -> ret m {mFrames = rest} v'
    FrIf env t el -> case v of
      VBool True -> Right (Just m {mCurrent = CurEval t env, mFrames = rest})
      VBool False -> Right (Just m {mCurrent = CurEval el env, mFrames = rest})
      _ -> Left (EvalErr (Trap "if condition is not Bool"))
    FrMatch env arms -> matchReturn m env v arms rest
    FrPar pjs
      | null pjs.pjsSlots -> case v of
          VList items ->
            let pjs' =
                  pjs
                    { pjsItems = items,
                      pjsSlots = replicate (length items) ParSlotPending
                    }
             in if null items
                  then ret m {mFrames = rest} (VList [])
                  else
                    Right
                      ( Just
                          m
                            { mCurrent = CurParPool,
                              mFrames = FrPar pjs' : rest
                            }
                      )
          _ -> Left (EvalErr (Trap "par source is not a list"))
      | otherwise -> Left (EvalErr (Trap "unexpected return into active FrPar"))
    FrTry {} -> ret m {mFrames = rest} v
    FrConfirm _ -> case confirmFromValue v of
      Left e -> Left e
      Right c ->
        Right
          ( Just
              m
                { mCurrent = CurAwaitConfirm c,
                  mFrames = FrConfirm c : rest
                }
          )
    FrChoice _ -> case choiceFromValue v of
      Left e -> Left e
      Right c ->
        Right
          ( Just
              m
                { mCurrent = CurAwaitChoice c,
                  mFrames = FrChoice c : rest
                }
          )
    FrAsk _ -> case askFromValue v of
      Left e -> Left e
      Right a ->
        Right
          ( Just
              m
                { mCurrent = CurAwaitAsk a,
                  mFrames = FrAsk a : rest
                }
          )
    FrAfterConfirm _ ->
      Left (EvalErr (Trap "unexpected return into FrAfterConfirm"))
    FrExecApproved ->
      Left (EvalErr (Trap "unexpected return into FrExecApproved"))
    FrRegion sid ->
      Right (Just m {mCurrent = CurCloseRegion sid v, mFrames = rest})
    FrJoin acc env es -> case es of
      [] -> ret m {mFrames = rest} (VList (reverse (v : acc)))
      e : es' ->
        Right
          ( Just
              m
                { mCurrent = CurEval e env,
                  mFrames = FrJoin (v : acc) env es' : rest
                }
          )
    FrInvoke {} ->
      Left (EvalErr (Trap "unexpected return into FrInvoke"))

applyOrArgs ::
  RunCtx ->
  Machine ->
  Value ->
  [(Maybe Ident, Value)] ->
  Env ->
  [Arg] ->
  [Frame] ->
  Either RuntimeError (Maybe Machine)
applyOrArgs ctx m f collected env args rest = case args of
  [] -> case openApply ctx f (reverse collected) of
    Left e -> Left e
    Right c -> Right (Just m {mCurrent = c, mFrames = rest})
  (a : as) ->
    Right
      ( Just
          m
            { mCurrent = CurEval (argExpr a) env,
              mFrames = FrAppArgs f collected env (a : as) : rest
            }
      )

argExpr :: Arg -> Expr
argExpr = \case
  ArgPos e -> e
  ArgNamed _ e -> e

argName :: Arg -> Maybe Ident
argName = \case
  ArgPos _ -> Nothing
  ArgNamed n _ -> Just n

matchReturn ::
  Machine ->
  Env ->
  Value ->
  [MatchArm] ->
  [Frame] ->
  Either RuntimeError (Maybe Machine)
matchReturn m env v arms rest = case arms of
  [] -> Left (EvalErr (Trap "non-exhaustive match"))
  MatchArm p body : more -> case matchPat p v of
    Nothing -> matchReturn m env v more rest
    Just binds ->
      Right
        ( Just
            m
              { mCurrent = CurEval body (extendEnvMany binds env),
                mFrames = rest
              }
        )

project :: Value -> Ident -> Either EvalError Value
project v f = case v of
  VRecord fs ->
    maybe (Left (Trap ("missing field: " <> unIdent f))) Right (lookup f fs)
  _ -> Left (Trap ("projection on non-record: " <> unIdent f))

indexList :: Value -> Value -> Either EvalError Value
indexList v ix = case (v, ix) of
  (VList xs, VInt i)
    | i < 0 || i >= fromIntegral (length xs) -> Left (Trap "list index out of bounds")
    | otherwise -> Right (xs !! fromIntegral i)
  (VList _, _) -> Left (Trap "list index is not Int")
  _ -> Left (Trap "index on non-list")

literalValue :: Literal -> Value
literalValue = \case
  LUnit -> VUnit
  LBool b -> VBool b
  LInt n -> VInt n
  LFloat d -> VFloat d
  LString t -> VString t

confirmFromValue :: Value -> Either RuntimeError ConfirmRequest
confirmFromValue = \case
  VRecord fs ->
    Right
      ConfirmRequest
        { crTitle = stringField (Ident "title") fs,
          crDetail = stringField (Ident "detail") fs,
          crBranchIndex = Nothing
        }
  _ -> Left (HostErr "confirm expects a record { title, detail }")

stringField :: Ident -> [(Ident, Value)] -> Text
stringField n fs = case lookup n fs of
  Just (VString t) -> t
  _ -> ""

confirmArgs :: [(Maybe Ident, Value)] -> Either RuntimeError ConfirmRequest
confirmArgs args = case lookup (Just (Ident "title")) args of
  Just (VString title) ->
    let detail = case lookup (Just (Ident "detail")) args of
          Just (VString d) -> d
          _ -> ""
     in Right (ConfirmRequest title detail Nothing)
  _ -> case args of
    [(Nothing, v)] -> confirmFromValue v
    _ -> Left (HostErr "human.confirm expects title: String (and optional detail)")

choiceFromValue :: Value -> Either RuntimeError ChoiceRequest
choiceFromValue = \case
  VRecord fs -> do
    opts <- optionsField fs
    pure
      ChoiceRequest
        { chTitle = stringField (Ident "title") fs,
          chDetail = stringField (Ident "detail") fs,
          chOptions = opts,
          chBranchIndex = Nothing
        }
  _ -> Left (HostErr "choice expects a record { title, detail, options }")

optionsField :: [(Ident, Value)] -> Either RuntimeError [Text]
optionsField fs = case lookup (Ident "options") fs of
  Just (VList xs) -> traverse expectOptionString xs >>= nonEmptyOptions
  Just _ -> Left (HostErr "choice.options must be List<String>")
  Nothing -> Left (HostErr "choice requires options: List<String>")

expectOptionString :: Value -> Either RuntimeError Text
expectOptionString = \case
  VString t -> Right t
  _ -> Left (HostErr "choice.options elements must be String")

nonEmptyOptions :: [Text] -> Either RuntimeError [Text]
nonEmptyOptions [] = Left (HostErr "choice.options must be non-empty")
nonEmptyOptions xs = Right xs

choiceArgs :: [(Maybe Ident, Value)] -> Either RuntimeError ChoiceRequest
choiceArgs args = case lookup (Just (Ident "options")) args of
  Just (VList xs) -> do
    opts <- traverse expectOptionString xs >>= nonEmptyOptions
    let title = case lookup (Just (Ident "title")) args of
          Just (VString t) -> t
          _ -> ""
        detail = case lookup (Just (Ident "detail")) args of
          Just (VString d) -> d
          _ -> ""
    pure (ChoiceRequest title detail opts Nothing)
  Just _ -> Left (HostErr "human.choice options must be List<String>")
  Nothing -> case args of
    [(Nothing, v)] -> choiceFromValue v
    _ -> Left (HostErr "human.choice expects options: List<String> (and optional title/detail)")

askFromValue :: Value -> Either RuntimeError AskRequest
askFromValue = \case
  VRecord fs -> case lookup (Ident "prompt") fs of
    Just (VString prompt) ->
      Right
        AskRequest
          { askPrompt = prompt,
            askDetail = stringField (Ident "detail") fs,
            askBranchIndex = Nothing
          }
    _ -> Left (HostErr "ask expects a record { prompt: String, detail?: String }")
  _ -> Left (HostErr "ask expects a record { prompt: String, detail?: String }")

askArgs :: [(Maybe Ident, Value)] -> Either RuntimeError AskRequest
askArgs args = case lookup (Just (Ident "prompt")) args of
  Just (VString prompt) ->
    let detail = case lookup (Just (Ident "detail")) args of
          Just (VString d) -> d
          _ -> ""
     in Right (AskRequest prompt detail Nothing)
  Just _ -> Left (HostErr "human.ask prompt must be String")
  Nothing -> case args of
    [(Nothing, v)] -> askFromValue v
    _ -> Left (HostErr "human.ask expects prompt: String (and optional detail)")

-- | Persist the root machine snapshot. Returns 'Just' seq when a snapshot was
-- written; 'Nothing' when nested (@rcNestDepth > 0@) so branch machines never
-- overwrite root @snapshot.json@.
persist ::
  RunCtx ->
  Maybe HostOpId ->
  Maybe Value ->
  MachineStatus ->
  Maybe Machine ->
  IO (Maybe Int)
persist ctx mHost mVal status mMachine
  | ctx.rcNestDepth > 0 = pure Nothing
  | otherwise = do
      stack <- getSpanStack ctx.rcSpans
      counter <- readIORef ctx.rcSpans.ssCounter
      persistTransition
        ctx.rcStore
        ctx.rcSeq
        ctx.rcProjectHash
        mHost
        mVal
        status
        mMachine
        stack
        counter
      Just <$> readIORef ctx.rcSeq
