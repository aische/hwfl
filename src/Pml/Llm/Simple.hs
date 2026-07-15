-- | Default 'LlmProvider' adapter over llm-simple. Only this module depends
-- on the llm-simple package — workflows must not import it.
module Pml.Llm.Simple
  ( mkSimpleProvider,
    mkSimpleProviderWithCatalog,
  )
where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import Data.Text qualified as T
import LLM.Core.Types (ChatResponse (..))
import LLM.Core.Types qualified as LLM
import LLM.Core.Usage qualified as LLMUsage
import LLM.Generate
  ( GenerateError (..),
    GenRequest (..),
    ModelWithFallbacks (..),
    generateTextWithFallbacks,
    llmHooks,
    noHooks,
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
      let (systemMsg, turns) = splitSystem req.chatMessages
          gr =
            GenRequest
              { grSystemPrompt = systemMsg,
                grMessages = turns,
                grTools = [],
                grAbortSignal = Nothing,
                grLLMHooks = llmHooks noHooks,
                grHooks = noHooks
              }
          models = ModelWithFallbacks model []
      result <- generateTextWithFallbacks gr models
      pure $ case result of
        Left genErr -> Left (mapGenerateError genErr)
        Right resp ->
          Right
            ProviderResult
              { prContent = resp.respText,
                prUsage = fmap mapUsage resp.respUsage,
                prFinishReason = FinishStop
              }

splitSystem :: [Message] -> (Maybe Text, [LLM.Turn])
splitSystem ms =
  let systems = [m.msgContent | m <- ms, m.msgRole == RoleSystem]
      rest =
        [ case m.msgRole of
            RoleUser -> LLM.UserTurn m.msgContent
            RoleAssistant -> LLM.AssistantTurn m.msgContent Nothing []
            RoleSystem -> LLM.UserTurn m.msgContent
          | m <- ms,
            m.msgRole /= RoleSystem
        ]
   in (case systems of [] -> Nothing; (s : _) -> Just s, rest)

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
