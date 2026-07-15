-- | Deterministic mock 'LlmProvider' for tests (no network).
module Pml.Llm.Mock
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
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types

-- | Default mock: echoes a summary of the last user message (no tool calls).
-- When 'chatResponseFormat' is set, synthesizes a JSON value from the schema.
mockProvider :: LlmProvider
mockProvider = mockProviderWith defaultReply

-- | Mock with a custom reply function.
mockProviderWith :: (ChatRequest -> Either ProviderError ProviderResult) -> LlmProvider
mockProviderWith reply =
  LlmProvider
    { llmChat = pure . reply,
      llmProviderName = "mock"
    }

defaultReply :: ChatRequest -> Either ProviderError ProviderResult
defaultReply req =
  let prompt = lastUserText req
   in case req.chatResponseFormat of
        Just schema ->
          Right
            ProviderResult
              { prContent = encodeJson (fillSchema prompt schema),
                prToolCalls = [],
                prUsage = Just (TokenUsage 1 1),
                prFinishReason = FinishStop
              }
        Nothing ->
          Right
            ProviderResult
              { prContent = "SUMMARY: " <> T.take 200 prompt,
                prToolCalls = [],
                prUsage = Just (TokenUsage 1 1),
                prFinishReason = FinishStop
              }

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
