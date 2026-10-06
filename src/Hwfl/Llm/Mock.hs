-- | Deterministic mock 'LlmProvider' for tests (no network).
module Hwfl.Llm.Mock
  ( mockProvider,
    mockProviderWith,
  )
where

import Data.Aeson (Value (..), encode, object)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types

-- | Default mock: echoes a summary of the last user message (no tool calls).
-- When 'chatResponseFormat' is set, synthesizes a JSON value from the schema.
-- When 'chatOnChunk' is set (and not object mode), emits fake text chunks.
mockProvider :: LlmProvider
mockProvider = mockProviderWith defaultReply

-- | Mock with a custom reply function.
mockProviderWith :: (ChatRequest -> Either ProviderError ProviderResult) -> LlmProvider
mockProviderWith reply =
  LlmProvider
    { llmChat = \req -> case reply req of
        Left err -> pure (Left err)
        Right pr -> do
          emitFakeChunks req pr
          pure (Right pr),
      llmProviderName = "mock"
    }

-- | Split the final reply into small deltas in part order so streaming-span
-- tests need no network. Opaque thinking payloads are not streamed.
emitFakeChunks :: ChatRequest -> ProviderResult -> IO ()
emitFakeChunks req pr =
  case (req.chatOnChunk, req.chatResponseFormat) of
    (Just onChunk, Nothing) -> mapM_ (emitPart onChunk) pr.prParts
    _ -> pure ()

emitPart :: (StreamDelta -> IO ()) -> AssistantPart -> IO ()
emitPart onChunk = \case
  AssistantText t -> mapM_ (onChunk . DeltaText) (chunkText 8 t)
  AssistantThinking tc ->
    case tc.thinkingText of
      Just t | not (T.null t) -> mapM_ (onChunk . DeltaReasoning) (chunkText 8 t)
      _ -> pure ()
  AssistantToolCall tc -> onChunk (DeltaToolCall tc)

chunkText :: Int -> Text -> [Text]
chunkText n t
  | T.null t = []
  | otherwise =
      let (a, b) = T.splitAt n t
       in a : chunkText n b

defaultReply :: ChatRequest -> Either ProviderError ProviderResult
defaultReply req =
  let prompt = lastUserText req
   in case req.chatResponseFormat of
        Just schema ->
          Right $
            providerResultText
              (encodeJson (fillSchema prompt schema))
              (Just (mkTokenUsage 1 1))
              FinishStop
        Nothing ->
          Right $
            providerResultText
              ("SUMMARY: " <> T.take 200 prompt)
              (Just (mkTokenUsage 1 1))
              FinishStop

encodeJson :: Value -> Text
encodeJson = TE.decodeUtf8 . BL.toStrict . encode

-- | Walk a JSON Schema and produce a placeholder value (CI-friendly structured output).
fillSchema :: Text -> Value -> Value
fillSchema prompt = go
  where
    go = \case
      Object o ->
        case KM.lookup "type" o of
          Just (String "object") ->
            case KM.lookup "properties" o of
              Just (Object props) ->
                Object $
                  KM.fromList
                    [ (k, fillProp (Key.toText k) v)
                      | (k, v) <- KM.toList props
                    ]
              _ -> object []
          Just (String "array") ->
            case KM.lookup "items" o of
              Just items -> Array (V.singleton (go items))
              Nothing -> Array V.empty
          Just (String "string") -> String (T.take 200 prompt)
          Just (String "integer") -> Number 1
          Just (String "number") -> Number 1.0
          Just (String "boolean") -> Bool True
          Just (String "null") -> Null
          _ ->
            case KM.lookup "anyOf" o of
              Just (Array xs) | not (V.null xs) -> go (V.head xs)
              _ ->
                case KM.lookup "oneOf" o of
                  Just (Array xs) | not (V.null xs) -> go (V.head xs)
                  _ -> Null
      other -> other
    fillProp k v
      | k == "summary" = String ("SUMMARY: " <> T.take 180 prompt)
      | otherwise = go v

lastUserText :: ChatRequest -> Text
lastUserText req
  | not (null req.chatTurns) =
      case [t | TurnUser t <- req.chatTurns] of
        [] -> ""
        xs -> last xs
  | otherwise =
      case [m.msgContent | m <- req.chatMessages, m.msgRole == RoleUser] of
        [] -> ""
        xs -> last xs
