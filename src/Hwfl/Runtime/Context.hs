-- | Agent context window and history-slice helpers (Context L1).
-- Full 'agHistory' remains snapshot / resume truth; these pure views shape
-- what the provider sees and what @get_history@ returns.
module Hwfl.Runtime.Context
  ( windowOffset,
    windowTurns,
    wireTurns,
    getHistoryChunk,
    historyToolName,
    historyToolDescription,
    historyToolParameters,
    defaultMaxToolResultChars,
    capToolResult,
    capTurnToolResults,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Llm.Types (ToolCall (..), ToolResult (..), Turn (..))

-- | Default per-tool-result char budget when @context_window@ is set and
-- @max_tool_result_chars@ is omitted. Large enough for typical file reads;
-- small enough that one bloated tool row cannot erase the window savings.
defaultMaxToolResultChars :: Int
defaultMaxToolResultChars = 16000

historyToolName :: Text
historyToolName = "get_history"

historyToolDescription :: Text
historyToolDescription =
  "Retrieve earlier conversation history that is not in your current context window. "
    <> "Pass chunk=0 for the most recent hidden history, chunk=1 for the one before that, etc. "
    <> "Returns an empty result when there is no more history."

historyToolParameters :: Aeson.Value
historyToolParameters =
  object
    [ "type" .= Aeson.String "object",
      "properties"
        .= object
          [ "chunk"
              .= object
                [ "type" .= Aeson.String "integer",
                  "description"
                    .= Aeson.String
                      "0 = most recent hidden chunk, 1 = the one before that, etc."
                ]
          ],
      "required" .= [Aeson.String "chunk" :: Aeson.Value],
      "additionalProperties" .= False
    ]

-- | Index where the visible window starts. Includes the last @n@ user turns
-- and all follow-on assistant / tool turns. @Nothing@ or fewer than @n@ user
-- turns → @0@ (full transcript).
windowOffset :: Maybe Int -> [Turn] -> Int
windowOffset Nothing _ = 0
windowOffset (Just n) conv
  | n <= 0 = 0
  | otherwise = findNthUserFromEnd n conv

windowTurns :: Maybe Int -> [Turn] -> [Turn]
windowTurns mWin hist = drop (windowOffset mWin hist) hist

-- | Window, then optionally cap tool-result payloads for the wire view.
-- Does not mutate the durable transcript.
wireTurns :: Maybe Int -> Maybe Int -> [Turn] -> [Turn]
wireTurns mWin mMax hist =
  map (capTurnToolResults mMax) (windowTurns mWin hist)

-- | Page hidden history. Chunk size matches the visible window's user-turn
-- count (same paging model as llm-simple @get_history@).
getHistoryChunk :: Maybe Int -> [Turn] -> Int -> Text
getHistoryChunk mWin hist chunkIdx =
  let offset = windowOffset mWin hist
      hidden = take offset hist
   in if null hidden
        then "(no earlier history)"
        else
          let nUser = countUserTurns (drop offset hist)
              pageSize = max 1 nUser
              chunks = chunkBackward pageSize hidden
           in if chunkIdx < 0 || chunkIdx >= length chunks
                then "(no more history)"
                else formatChunk (chunks !! chunkIdx)

capTurnToolResults :: Maybe Int -> Turn -> Turn
capTurnToolResults Nothing t = t
capTurnToolResults (Just n) t = case t of
  TurnTool rs -> TurnTool (map (capOne n) rs)
  other -> other
  where
    capOne maxChars r = r {trContent = capToolResult maxChars r.trContent}

capToolResult :: Int -> Text -> Text
capToolResult maxChars t
  | maxChars <= 0 = t
  | T.length t <= maxChars = t
  | otherwise =
      T.take maxChars t
        <> "\n…[truncated "
        <> T.pack (show (T.length t - maxChars))
        <> " chars]"

-------------------------------------------------------------------------------
-- Internals (llm-simple-compatible window / chunk algebra)

findNthUserFromEnd :: Int -> [Turn] -> Int
findNthUserFromEnd 0 _ = 0
findNthUserFromEnd n conv = go (length conv - 1) n
  where
    go idx remaining
      | idx < 0 = 0
      | remaining <= 0 = idx + 1
      | otherwise = case conv !! idx of
          TurnUser _ -> go (idx - 1) (remaining - 1)
          _ -> go (idx - 1) remaining

countUserTurns :: [Turn] -> Int
countUserTurns = length . filter isUserTurn

isUserTurn :: Turn -> Bool
isUserTurn (TurnUser _) = True
isUserTurn _ = False

-- | Split into pages of @n@ user messages each, working backward from the end.
-- Chunk 0 is the most recent page.
chunkBackward :: Int -> [Turn] -> [[Turn]]
chunkBackward _ [] = []
chunkBackward n conv = reverse (go (length conv) [])
  where
    go 0 acc = acc
    go end acc =
      let start = findNthUserBack n (take end conv)
          page = slice start end conv
       in go start (page : acc)

findNthUserBack :: Int -> [Turn] -> Int
findNthUserBack n conv = go (length conv - 1) n
  where
    go idx remaining
      | idx < 0 = 0
      | remaining <= 0 = idx + 1
      | otherwise = case conv !! idx of
          TurnUser _ -> go (idx - 1) (remaining - 1)
          _ -> go (idx - 1) remaining

slice :: Int -> Int -> [a] -> [a]
slice start end = take (end - start) . drop start

formatChunk :: [Turn] -> Text
formatChunk = T.intercalate "\n" . map formatTurn

formatTurn :: Turn -> Text
formatTurn (TurnUser t) = "[User] " <> t
formatTurn (TurnAssistant t calls) =
  "[Assistant] "
    <> t
    <> if null calls
      then ""
      else " [called: " <> T.intercalate ", " (map (.tcName) calls) <> "]"
formatTurn (TurnTool results) =
  "[Tool results] "
    <> T.intercalate
      ", "
      [r.trName <> ": " <> T.take 200 r.trContent | r <- results]
