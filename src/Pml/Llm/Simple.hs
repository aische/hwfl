-- | Default 'LlmProvider' adapter over llm-simple. Only this module depends
-- on the llm-simple package — workflows must not import it.
module Pml.Llm.Simple
  ( mkSimpleProvider,
    mkSimpleProviderWithCatalog,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import LLM.Core.Types (ChatResponse (..), ContentBlock (..), ToolDef (..))
import LLM.Core.Types qualified as LLM
import LLM.Core.Usage qualified as LLMUsage
import LLM.Generate
  ( GenerateError (..),
    GenerateErrorResult (..),
    GenRequest (..),
    ModelWithFallbacks (..),
    generateTextWithFallbacks,
    genObjectUntyped,
    llmHooks,
    noHooks,
    defaultDebugHooks,
  )
import LLM.Load (loadModelOrThrow)
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types as Pml
import System.Directory (doesFileExist)

-- | Build the default adapter. Requires a readable model catalog path.
mkSimpleProvider :: FilePath -> IO (Either Text LlmProvider)
mkSimpleProvider catalogPath = do
  exists <- doesFileExist catalogPath
  if not exists
    then
      pure $
        Left $
          "llm-simple provider: model catalog not found at "
            <> T.pack catalogPath
            <> " (pass a catalog or use --llm-provider=mock)"
    else pure (Right (mkSimpleProviderWithCatalog catalogPath))

-- | Provider that resolves @model@ names via the catalog on each call.
-- Retries/timeouts live in llm-simple's generate layer (M4 choice).
mkSimpleProviderWithCatalog :: FilePath -> LlmProvider
mkSimpleProviderWithCatalog catalogPath =
  LlmProvider
    { llmChat = chatWithCatalog catalogPath,
      llmProviderName = "simple"
    }

chatWithCatalog :: FilePath -> ChatRequest -> IO (Either ProviderError ProviderResult)
chatWithCatalog catalogPath req = do
  loaded <- try (loadModelOrThrow catalogPath req.chatModel)
  case loaded of
    Left (ex :: SomeException) ->
      pure (Left (OtherProviderError (T.pack (show ex))))
    Right model -> do
      let (systemMsg, turns) = requestToTurns req
          gr =
            GenRequest
              { grSystemPrompt = systemMsg,
                grMessages = turns,
                grTools = map toLLMTool req.chatTools,
                grAbortSignal = Nothing,
                grLLMHooks = llmHooks defaultDebugHooks,
                grHooks = noHooks
              }
          models = ModelWithFallbacks model []
      case req.chatResponseFormat of
        Nothing -> do
          result <- generateTextWithFallbacks gr models
          pure $ case result of
            Left genErr -> Left (mapGenerateError genErr)
            Right resp ->
              let toolCalls = [fromLLMToolCall tc | ToolCallBlock tc <- resp.respContent]
                  finish =
                    if null toolCalls
                      then FinishStop
                      else FinishToolCalls
               in Right
                    ProviderResult
                      { prContent = resp.respText,
                        prToolCalls = toolCalls,
                        prUsage = fmap mapUsage resp.respUsage,
                        prFinishReason = finish
                      }
        Just schema -> do
          -- Structured object path: tools must stay empty (llm-simple contract).
          let grObj = gr {grTools = []}
          result <- genObjectUntyped grObj models schema
          pure $ case result of
            Left ger -> Left (mapGenerateError ger.gerError)
            Right (val, usage) ->
              Right
                ProviderResult
                  { prContent = TE.decodeUtf8 (BL.toStrict (Aeson.encode val)),
                    prToolCalls = [],
                    prUsage = Just (mapUsage usage),
                    prFinishReason = FinishStop
                  }

requestToTurns :: ChatRequest -> (Maybe Text, [LLM.Turn])
requestToTurns req
  | not (null req.chatTurns) =
      ( req.chatSystem,
        map toLLMTurn req.chatTurns
      )
  | otherwise =
      let systems =
            case req.chatSystem of
              Just s -> [s]
              Nothing -> [m.msgContent | m <- req.chatMessages, m.msgRole == RoleSystem]
          rest =
            [ case m.msgRole of
                RoleUser -> LLM.UserTurn m.msgContent
                RoleAssistant -> LLM.AssistantTurn m.msgContent Nothing []
                RoleSystem -> LLM.UserTurn m.msgContent
              | m <- req.chatMessages,
                m.msgRole /= RoleSystem
            ]
       in (case systems of [] -> Nothing; (s : _) -> Just s, rest)

toLLMTurn :: Turn -> LLM.Turn
toLLMTurn = \case
  TurnUser t -> LLM.UserTurn t
  TurnAssistant t calls ->
    LLM.AssistantTurn t Nothing (map toLLMToolCall calls)
  TurnTool results ->
    LLM.ToolTurn
      [ LLM.ToolResult r.trCallId r.trName r.trContent
        | r <- results
      ]

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
  LLM.mkToolCall tc.tcId tc.tcName tc.tcArguments

fromLLMToolCall :: LLM.ToolCall -> ToolCall
fromLLMToolCall tc =
  ToolCall
    { tcId = tc.tcId,
      tcName = tc.tcName,
      tcArguments = tc.tcArguments
    }

mapUsage :: LLMUsage.Usage -> TokenUsage
mapUsage u =
  TokenUsage
    { usageInputTokens = u.usageInputTokens,
      usageOutputTokens = u.usageOutputTokens
    }

mapGenerateError :: GenerateError -> ProviderError
mapGenerateError = \case
  GErrLLM llmErr -> mapLLMError llmErr
  GErrToolExceeded -> OtherProviderError "tool loop exceeded"
  GErrAllModelsFailed -> OtherProviderError "all models failed"
  GErrAborted -> Pml.TimeoutError "aborted"
  GErrParseObjectError t -> InvalidRequestError t

mapLLMError :: LLM.LLMError -> ProviderError
mapLLMError = \case
  LLM.HttpError code body
    | code == 401 || code == 403 -> AuthError (T.pack (show code) <> " " <> body)
    | code == 429 -> RateLimitError body
    | otherwise -> OtherProviderError (T.pack (show code) <> " " <> body)
  LLM.NetworkError t -> OtherProviderError t
  LLM.TimeoutError -> Pml.TimeoutError "provider timeout"
  LLM.ParseError t -> OtherProviderError t
  LLM.EmptyResponse -> OtherProviderError "empty response"
  LLM.ToolLoopExceeded n -> OtherProviderError ("tool loop exceeded: " <> T.pack (show n))
  LLM.Aborted -> Pml.TimeoutError "aborted"
