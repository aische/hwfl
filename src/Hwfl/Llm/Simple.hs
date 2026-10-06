-- | Default 'LlmProvider' adapter over llm-simple. Only this module depends
-- on the llm-simple package — workflows must not import it.
module Hwfl.Llm.Simple
  ( mkSimpleProvider,
    mkSimpleProviderWithCatalog,
    mkSimpleProviderFromModel,
    requestToTurns,
    toLLMTurn,
    toLLMContentPart,
    fromLLMAssistantPart,
    toLLMOpaque,
    fromLLMOpaque,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types as Hwfl
import LLM.Core.Types
  ( ChatResponse (..),
    ContentPart (..),
    PartBody (..),
    ToolDef (..),
  )
import LLM.Core.Types qualified as LLM
import LLM.Core.Usage qualified as LLMUsage
import LLM.Generate
  ( GenRequest (..),
    GenerateError (..),
    GenerateErrorResult (..),
    ModelConfig,
    ModelWithFallbacks (..),
    StreamChunk (..),
    defaultDebugHooks,
    genObjectUntyped,
    generateTextWithFallbacks,
    llmHooks,
    noHooks,
    streamTextWithFallbacks,
  )
import LLM.Load (loadModelOrThrow)
import System.Directory (doesFileExist)

-- | Build the default adapter. Requires a readable model catalog path.
-- When @dump@ is true, llm-simple writes request/response JSON under @./dumps@.
mkSimpleProvider :: Bool -> FilePath -> IO (Either Text LlmProvider)
mkSimpleProvider dump catalogPath = do
  exists <- doesFileExist catalogPath
  if not exists
    then
      pure $
        Left $
          "llm-simple provider: model catalog not found at "
            <> T.pack catalogPath
            <> " (pass a catalog or use --llm-provider=mock)"
    else pure (Right (mkSimpleProviderWithCatalog dump catalogPath))

-- | Provider that resolves @model@ names via the catalog on each call.
-- Retries/timeouts live in llm-simple's generate layer (M4 choice).
mkSimpleProviderWithCatalog :: Bool -> FilePath -> LlmProvider
mkSimpleProviderWithCatalog dump catalogPath =
  LlmProvider
    { llmChat = chatWithCatalog dump catalogPath,
      llmProviderName = "simple"
    }

-- | Provider wired to a pre-built 'ModelConfig' (fixture gateways / offline tests).
--
-- Skips catalog load; uses the same generate/stream/object paths as the
-- catalog-backed adapter so ordered parts and opaque metadata round-trip
-- through the real llm-simple generate layer.
mkSimpleProviderFromModel :: Bool -> ModelConfig -> LlmProvider
mkSimpleProviderFromModel dump model =
  LlmProvider
    { llmChat = chatWithModels dump (ModelWithFallbacks model []),
      llmProviderName = "simple"
    }

chatWithCatalog :: Bool -> FilePath -> ChatRequest -> IO (Either ProviderError ProviderResult)
chatWithCatalog dump catalogPath req = do
  loaded <- try (loadModelOrThrow catalogPath req.chatModel)
  case loaded of
    Left (ex :: SomeException) ->
      pure (Left (OtherProviderError (T.pack (show ex))))
    Right model ->
      chatWithModels dump (ModelWithFallbacks model []) req

chatWithModels :: Bool -> ModelWithFallbacks -> ChatRequest -> IO (Either ProviderError ProviderResult)
chatWithModels dump models req = do
  let hooks = if dump then defaultDebugHooks else noHooks
      (systemMsg, turns) = requestToTurns req
      gr =
        GenRequest
          { grSystemPrompt = systemMsg,
            grMessages = map toLLMTurn turns,
            grTools = map toLLMTool req.chatTools,
            grAbortSignal = Nothing,
            grLLMHooks = llmHooks hooks,
            grHooks = noHooks
          }
  case req.chatResponseFormat of
    Nothing -> do
      result <- case req.chatOnChunk of
        Nothing -> generateTextWithFallbacks gr models
        Just onChunk ->
          streamTextWithFallbacks (mapStreamChunk onChunk) gr models
      pure $ case result of
        Left genErr -> Left (mapGenerateError genErr)
        Right resp ->
          let parts = mapMaybe fromLLMAssistantPart resp.respContent
              finish =
                if null (assistantToolCalls parts)
                  then FinishStop
                  else FinishToolCalls
           in Right (mkProviderResult parts (fmap mapUsage resp.respUsage) finish)
    Just schema -> do
      -- Structured object path: tools must stay empty (llm-simple contract).
      -- Object mode stays on the non-stream generate path (spec §08 §2.2).
      let grObj = gr {grTools = []}
      result <- genObjectUntyped grObj models schema
      pure $ case result of
        Left ger -> Left (mapGenerateError ger.gerError)
        Right (val, usage) ->
          Right $
            providerResultText
              (TE.decodeUtf8 (BL.toStrict (Aeson.encode val)))
              (Just (mapUsage usage))
              FinishStop

-- | Map llm-simple stream chunks onto engine 'StreamDelta's. Role-commit
-- signals are internal and dropped; tool calls are complete only.
mapStreamChunk :: (StreamDelta -> IO ()) -> StreamChunk -> IO ()
mapStreamChunk onChunk = \case
  AnswerDelta t -> onChunk (DeltaText t)
  PreambleDelta t -> onChunk (DeltaText t)
  TextDelta t -> onChunk (DeltaText t)
  ReasoningDelta t -> onChunk (DeltaReasoning t)
  RoundTextRoleCommitted _ -> pure ()
  StreamToolCallChunk tc -> onChunk (DeltaToolCall (fromLLMToolCall tc))

-- | Collapse a 'ChatRequest' into llm-simple's single system slot + turns.
-- Message-path requests may carry several 'RoleSystem' entries (and an optional
-- 'chatSystem'); all non-empty system texts are joined so none are dropped.
-- When 'chatTurns' is non-empty, 'chatSystem' is used as-is (agent path).
requestToTurns :: ChatRequest -> (Maybe Text, [Turn])
requestToTurns req
  | not (null req.chatTurns) =
      (req.chatSystem, req.chatTurns)
  | otherwise =
      let fromMsgs = [m.msgContent | m <- req.chatMessages, m.msgRole == RoleSystem]
          -- Host prepends chatSystem as the first RoleSystem message; avoid
          -- duplicating that copy when both are present.
          systems =
            case req.chatSystem of
              Just s
                | Just s == listToMaybe fromMsgs -> fromMsgs
                | otherwise -> s : fromMsgs
              Nothing -> fromMsgs
          joined =
            case filter (not . T.null) systems of
              [] -> Nothing
              xs -> Just (T.intercalate "\n\n" xs)
          rest =
            mapMaybe
              ( \m -> case m.msgRole of
                  RoleUser -> Just (TurnUser m.msgContent)
                  RoleAssistant -> Just (turnAssistantText m.msgContent)
                  RoleSystem -> Nothing
              )
              req.chatMessages
       in (joined, rest)

toLLMTurn :: Turn -> LLM.Turn
toLLMTurn = \case
  TurnUser t -> LLM.UserTurn t
  TurnAssistant parts ->
    LLM.AssistantMessage (map toLLMContentPart parts)
  TurnTool results ->
    LLM.ToolTurn
      [ LLM.ToolResult r.trCallId r.trName r.trContent
        | r <- results
      ]

toLLMContentPart :: AssistantPart -> LLM.ContentPart
toLLMContentPart = \case
  AssistantText t -> LLM.textPart t
  AssistantThinking tc ->
    LLM.thinkingPart
      ( LLM.ThinkingContent
          { LLM.thinkingText = tc.thinkingText,
            LLM.thinkingOpaque = fmap toLLMOpaque tc.thinkingOpaque
          }
      )
  AssistantToolCall tc -> LLM.toolCallPart (toLLMToolCall tc)

fromLLMAssistantPart :: ContentPart -> Maybe AssistantPart
fromLLMAssistantPart (ContentPart body _) = case body of
  TextPart t -> Just (AssistantText t)
  ThinkingPart tc ->
    Just $
      AssistantThinking
        ThinkingContent
          { thinkingText = tc.thinkingText,
            thinkingOpaque = fmap fromLLMOpaque tc.thinkingOpaque
          }
  ToolCallPart tc -> Just (AssistantToolCall (fromLLMToolCall tc))
  ImagePart _ -> Nothing

toLLMTool :: ToolSpec -> LLM.ToolDef
toLLMTool ts =
  LLM.ToolDef
    { toolName = ts.tsName,
      toolDescription = ts.tsDescription,
      toolParameters = ts.tsParameters,
      toolReadonly = True
    }

toLLMToolCall :: ToolCall -> LLM.ToolCall
toLLMToolCall tc =
  LLM.ToolCall
    { LLM.tcId = tc.tcId,
      LLM.tcName = tc.tcName,
      LLM.tcArguments = tc.tcArguments,
      LLM.tcProviderMeta = fmap toLLMOpaque tc.tcProviderMeta
    }

fromLLMToolCall :: LLM.ToolCall -> ToolCall
fromLLMToolCall tc =
  ToolCall
    { tcId = tc.tcId,
      tcName = tc.tcName,
      tcArguments = tc.tcArguments,
      tcProviderMeta = fmap fromLLMOpaque tc.tcProviderMeta
    }

toLLMOpaque :: ProviderOpaque -> LLM.ProviderOpaque
toLLMOpaque po =
  LLM.ProviderOpaque
    { LLM.poProvider = po.poProvider,
      LLM.poModel = po.poModel,
      LLM.poPayload = po.poPayload
    }

fromLLMOpaque :: LLM.ProviderOpaque -> ProviderOpaque
fromLLMOpaque po =
  ProviderOpaque
    { poProvider = po.poProvider,
      poModel = po.poModel,
      poPayload = po.poPayload
    }

mapUsage :: LLMUsage.Usage -> TokenUsage
mapUsage u =
  TokenUsage
    { usageInputTokens = u.usageInputTokens,
      usageOutputTokens = u.usageOutputTokens,
      usageCacheReadTokens = u.usageCacheReadTokens,
      usageCacheCreationTokens = u.usageCacheCreationTokens
    }

mapGenerateError :: GenerateError -> ProviderError
mapGenerateError = \case
  GErrLLM llmErr -> mapLLMError llmErr
  GErrToolExceeded -> OtherProviderError "tool loop exceeded"
  GErrAllModelsFailed -> OtherProviderError "all models failed"
  GErrAborted -> Hwfl.TimeoutError "aborted"
  GErrParseObjectError t -> InvalidRequestError t

mapLLMError :: LLM.LLMError -> ProviderError
mapLLMError = \case
  LLM.HttpError code body
    | code == 401 || code == 403 -> AuthError (T.pack (show code) <> " " <> body)
    | code == 429 -> RateLimitError body
    | otherwise -> OtherProviderError (T.pack (show code) <> " " <> body)
  LLM.NetworkError t -> OtherProviderError t
  LLM.TimeoutError -> Hwfl.TimeoutError "provider timeout"
  LLM.ParseError t -> OtherProviderError t
  LLM.EmptyResponse -> OtherProviderError "empty response"
  LLM.ToolLoopExceeded n -> OtherProviderError ("tool loop exceeded: " <> T.pack (show n))
  LLM.Aborted -> Hwfl.TimeoutError "aborted"
  LLM.UnsupportedCapability msg -> InvalidRequestError msg
