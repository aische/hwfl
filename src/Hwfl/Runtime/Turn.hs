-- | Agent turn values: language/runtime bridge and snapshot JSON codec.
module Hwfl.Runtime.Turn
  ( turnToValue,
    valueToTurn,
    turnsToValue,
    valueToTurns,
    turnToJson,
    turnToPublicJson,
    parseTurn,
    toolCallToJson,
    toolCallToPublicJson,
    parseToolCall,
    toolResultToJson,
    parseToolResult,
    assistantPartToJson,
    assistantPartToPublicJson,
    parseAssistantPart,
    providerOpaqueToJson,
    parseProviderOpaque,
  )
where

import Data.Aeson (object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Eval.Value qualified as V
import Hwfl.Llm.Types
  ( AssistantPart (..),
    ProviderOpaque (..),
    ThinkingContent (..),
    ToolCall (..),
    ToolResult (..),
    Turn (..),
    turnAssistantTextTools,
  )
import Hwfl.Runtime.Error (RuntimeError (..))

turnToValue :: Turn -> V.Value
turnToValue = V.VTurn

valueToTurn :: V.Value -> Either RuntimeError Turn
valueToTurn = \case
  V.VTurn t -> Right t
  _ -> Left (HostErr "expected Turn value")

turnsToValue :: [Turn] -> V.Value
turnsToValue = V.VList . map turnToValue

valueToTurns :: V.Value -> Either RuntimeError [Turn]
valueToTurns = \case
  V.VList xs -> traverse valueToTurn xs
  _ -> Left (HostErr "expected List<Turn>")

-- | Canonical snapshot / resume encoding. Assistant turns use ordered @parts@
-- and preserve opaque provider replay state losslessly.
turnToJson :: Turn -> Aeson.Value
turnToJson = turnToJsonWith True

-- | Author-facing JSON encoding. Same ordered @parts@ shape, but omits opaque
-- provider payloads and tool-call provider metadata.
turnToPublicJson :: Turn -> Aeson.Value
turnToPublicJson = turnToJsonWith False

turnToJsonWith :: Bool -> Turn -> Aeson.Value
turnToJsonWith includeOpaque = \case
  TurnUser t -> object ["tag" .= Aeson.String "user", "text" .= t]
  TurnAssistant parts ->
    object
      [ "tag" .= Aeson.String "assistant",
        "parts" .= map (assistantPartToJsonWith includeOpaque) parts
      ]
  TurnTool results ->
    object ["tag" .= Aeson.String "tool", "results" .= map toolResultToJson results]

parseTurn :: Aeson.Value -> Parser Turn
parseTurn = withObject "Turn" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "user" -> TurnUser <$> o .: "text"
    "assistant" -> parseAssistantTurn o
    "tool" -> TurnTool <$> (o .: "results" >>= mapM parseToolResult)
    other -> fail ("unknown turn: " <> T.unpack other)

-- | New shape: @parts@. Legacy: @text@ + @calls@ (text first, then tool calls).
parseAssistantTurn :: Aeson.Object -> Parser Turn
parseAssistantTurn o = do
  mParts <- o .:? "parts"
  case mParts of
    Just parts -> TurnAssistant <$> mapM parseAssistantPart parts
    Nothing ->
      turnAssistantTextTools
        <$> o .: "text"
        <*> (o .: "calls" >>= mapM parseToolCall)

assistantPartToJson :: AssistantPart -> Aeson.Value
assistantPartToJson = assistantPartToJsonWith True

assistantPartToPublicJson :: AssistantPart -> Aeson.Value
assistantPartToPublicJson = assistantPartToJsonWith False

assistantPartToJsonWith :: Bool -> AssistantPart -> Aeson.Value
assistantPartToJsonWith includeOpaque = \case
  AssistantText t ->
    object ["tag" .= Aeson.String "text", "text" .= t]
  AssistantThinking tc ->
    object $
      ["tag" .= Aeson.String "thinking"]
        ++ maybeToList (("text" .=) <$> tc.thinkingText)
        ++ [ ("thinking_opaque" .= providerOpaqueToJson opaque)
             | includeOpaque,
               opaque <- maybeToList tc.thinkingOpaque
           ]
  AssistantToolCall tc ->
    object $
      [ "tag" .= Aeson.String "tool_call",
        "id" .= tc.tcId,
        "name" .= tc.tcName,
        "arguments" .= tc.tcArguments
      ]
        ++ [ ("provider_meta" .= providerOpaqueToJson meta)
             | includeOpaque,
               meta <- maybeToList tc.tcProviderMeta
           ]

parseAssistantPart :: Aeson.Value -> Parser AssistantPart
parseAssistantPart = withObject "AssistantPart" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "text" -> AssistantText <$> o .: "text"
    "thinking" -> do
      text <- o .:? "text"
      opaque <- o .:? "thinking_opaque" >>= traverse parseProviderOpaque
      pure (AssistantThinking (ThinkingContent text opaque))
    "tool_call" -> AssistantToolCall <$> parseToolCallObject o
    other -> fail ("unknown assistant part: " <> T.unpack other)

toolCallToJson :: ToolCall -> Aeson.Value
toolCallToJson tc =
  object $
    [ "id" .= tc.tcId,
      "name" .= tc.tcName,
      "arguments" .= tc.tcArguments
    ]
      ++ maybeToList
        ( ("provider_meta" .=) . providerOpaqueToJson
            <$> tc.tcProviderMeta
        )

-- | Tool call without provider metadata (author-facing / obs-safe).
toolCallToPublicJson :: ToolCall -> Aeson.Value
toolCallToPublicJson tc =
  object
    [ "id" .= tc.tcId,
      "name" .= tc.tcName,
      "arguments" .= tc.tcArguments
    ]

parseToolCall :: Aeson.Value -> Parser ToolCall
parseToolCall = withObject "ToolCall" parseToolCallObject

parseToolCallObject :: Aeson.Object -> Parser ToolCall
parseToolCallObject o = do
  tid <- o .: "id"
  name <- o .: "name"
  args <- o .: "arguments"
  meta <- o .:? "provider_meta" >>= traverse parseProviderOpaque
  pure
    ToolCall
      { tcId = tid,
        tcName = name,
        tcArguments = args,
        tcProviderMeta = meta
      }

toolResultToJson :: ToolResult -> Aeson.Value
toolResultToJson tr =
  object
    [ "call_id" .= tr.trCallId,
      "name" .= tr.trName,
      "content" .= tr.trContent
    ]

parseToolResult :: Aeson.Value -> Parser ToolResult
parseToolResult = withObject "ToolResult" $ \o ->
  ToolResult <$> o .: "call_id" <*> o .: "name" <*> o .: "content"

providerOpaqueToJson :: ProviderOpaque -> Aeson.Value
providerOpaqueToJson po =
  object $
    [ "provider" .= po.poProvider,
      "payload" .= po.poPayload
    ]
      ++ maybeToList (("model" .=) <$> po.poModel)

parseProviderOpaque :: Aeson.Value -> Parser ProviderOpaque
parseProviderOpaque = withObject "ProviderOpaque" $ \o ->
  ProviderOpaque
    <$> o .: "provider"
    <*> o .:? "model"
    <*> o .: "payload"
