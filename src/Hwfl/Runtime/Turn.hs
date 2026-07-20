-- | Agent turn values: language/runtime bridge and snapshot JSON codec.
module Hwfl.Runtime.Turn
  ( turnToValue,
    valueToTurn,
    turnsToValue,
    valueToTurns,
    turnToJson,
    parseTurn,
    toolCallToJson,
    parseToolCall,
    toolResultToJson,
    parseToolResult,
  )
where

import Data.Aeson (object, withObject, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, (.:))
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Eval.Value qualified as V
import Hwfl.Llm.Types (ToolCall (..), ToolResult (..), Turn (..))
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

turnToJson :: Turn -> Aeson.Value
turnToJson = \case
  TurnUser t -> object ["tag" .= Aeson.String "user", "text" .= t]
  TurnAssistant t calls ->
    object
      [ "tag" .= Aeson.String "assistant",
        "text" .= t,
        "calls" .= map toolCallToJson calls
      ]
  TurnTool results ->
    object ["tag" .= Aeson.String "tool", "results" .= map toolResultToJson results]

parseTurn :: Aeson.Value -> Parser Turn
parseTurn = withObject "Turn" $ \o -> do
  tag <- o .: "tag"
  case tag :: Text of
    "user" -> TurnUser <$> o .: "text"
    "assistant" ->
      TurnAssistant <$> o .: "text" <*> (o .: "calls" >>= mapM parseToolCall)
    "tool" -> TurnTool <$> (o .: "results" >>= mapM parseToolResult)
    other -> fail ("unknown turn: " <> T.unpack other)

toolCallToJson :: ToolCall -> Aeson.Value
toolCallToJson tc =
  object
    [ "id" .= tc.tcId,
      "name" .= tc.tcName,
      "arguments" .= tc.tcArguments
    ]

parseToolCall :: Aeson.Value -> Parser ToolCall
parseToolCall = withObject "ToolCall" $ \o ->
  ToolCall <$> o .: "id" <*> o .: "name" <*> o .: "arguments"

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
