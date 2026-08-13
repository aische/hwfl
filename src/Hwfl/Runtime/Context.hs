-- | Agent context window, history slices (L1), and consolidate/assemble (L2).
-- Full 'agHistory' remains snapshot / resume truth; these pure views shape
-- what the provider sees and what @get_history@ / pin tools return.
module Hwfl.Runtime.Context
  ( -- * L1 window / history
    windowOffset,
    windowTurns,
    wireTurns,
    getHistoryChunk,
    historyToolName,
    historyToolDescription,
    historyToolParameters,
    defaultMaxToolResultChars,
    capToolResult,
    capTurnToolResults,

    -- * L2 consolidate / pins
    ConsolidateMode (..),
    Pin (..),
    defaultMaxPins,
    defaultMaxSummaryChars,
    parseConsolidateMode,
    consolidateModeText,
    contextToolsEnabled,
    pinToolName,
    consolidateToolName,
    pinToolDescription,
    pinToolParameters,
    consolidateToolDescription,
    consolidateToolParameters,
    extractPins,
    heuristicSummary,
    mergePins,
    mergeSummary,
    assembleWireTurns,
    needsAutoCompact,
    compactDroppable,
    droppableSpan,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAlphaNum)
import Data.List (nubBy)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfl.Llm.Types (ToolCall (..), ToolResult (..), Turn (..))

-------------------------------------------------------------------------------
-- L1 defaults / history tool

-- | Default per-tool-result char budget when @context_window@ is set and
-- @max_tool_result_chars@ is omitted.
defaultMaxToolResultChars :: Int
defaultMaxToolResultChars = 16000

defaultMaxPins :: Int
defaultMaxPins = 32

defaultMaxSummaryChars :: Int
defaultMaxSummaryChars = 2000

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

-------------------------------------------------------------------------------
-- L2 modes / pin tools

-- | Author-facing @consolidate@ knob (@"llm"@ is rejected at parse until implemented).
data ConsolidateMode
  = ConsolidateOff
  | ConsolidateHeuristic
  | ConsolidateManual
  deriving stock (Eq, Show)

parseConsolidateMode :: Text -> Either Text ConsolidateMode
parseConsolidateMode t = case T.toLower (T.strip t) of
  "" -> Right ConsolidateOff
  "off" -> Right ConsolidateOff
  "false" -> Right ConsolidateOff
  "heuristic" -> Right ConsolidateHeuristic
  "manual" -> Right ConsolidateManual
  "llm" ->
    Left
      "consolidate=\"llm\" is not implemented yet; use \"heuristic\" or \"manual\""
  other ->
    Left
      ( "unknown consolidate mode "
          <> other
          <> "; expected heuristic, manual, or omit"
      )

consolidateModeText :: ConsolidateMode -> Maybe Text
consolidateModeText = \case
  ConsolidateOff -> Nothing
  ConsolidateHeuristic -> Just "heuristic"
  ConsolidateManual -> Just "manual"

contextToolsEnabled :: ConsolidateMode -> Bool
contextToolsEnabled = \case
  ConsolidateOff -> False
  ConsolidateHeuristic -> True
  ConsolidateManual -> True

data Pin = Pin
  { pinId :: Text,
    pinKind :: Text,
    pinText :: Text
  }
  deriving stock (Eq, Show)

pinToolName :: Text
pinToolName = "pin"

consolidateToolName :: Text
consolidateToolName = "consolidate"

pinToolDescription :: Text
pinToolDescription =
  "Store a durable note (pin) that will be prepended to future model context "
    <> "even after older turns leave the context window. Use for paths, decisions, "
    <> "constraints, and other facts you must not forget."

pinToolParameters :: Aeson.Value
pinToolParameters =
  object
    [ "type" .= Aeson.String "object",
      "properties"
        .= object
          [ "text"
              .= object
                [ "type" .= Aeson.String "string",
                  "description" .= Aeson.String "Pin body (required)"
                ],
            "kind"
              .= object
                [ "type" .= Aeson.String "string",
                  "description"
                    .= Aeson.String
                      "Optional kind such as note, path, decision (default note)"
                ]
          ],
      "required" .= [Aeson.String "text" :: Aeson.Value],
      "additionalProperties" .= False
    ]

consolidateToolDescription :: Text
consolidateToolDescription =
  "Fold older conversation turns that have left the context window into pins "
    <> "and a short earlier-context summary. Call when you need to refresh memory "
    <> "of hidden history; usually runs automatically when consolidate=heuristic."

consolidateToolParameters :: Aeson.Value
consolidateToolParameters =
  object
    [ "type" .= Aeson.String "object",
      "properties" .= object [],
      "additionalProperties" .= False
    ]

-------------------------------------------------------------------------------
-- L1 window

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
wireTurns :: Maybe Int -> Maybe Int -> [Turn] -> [Turn]
wireTurns mWin mMax hist =
  map (capTurnToolResults mMax) (windowTurns mWin hist)

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
-- L2 extract / merge / assemble

needsAutoCompact :: ConsolidateMode -> Maybe Int -> Int -> [Turn] -> Bool
needsAutoCompact ConsolidateHeuristic (Just n) watermark hist
  | n > 0 =
      let offset = windowOffset (Just n) hist
       in offset > watermark
needsAutoCompact _ _ _ _ = False

-- | Turns in @[watermark, windowOffset)@ — about to leave / already left the window.
droppableSpan :: Maybe Int -> Int -> [Turn] -> [Turn]
droppableSpan mWin watermark hist =
  let offset = windowOffset mWin hist
      start = max 0 (min watermark offset)
      end = max start offset
   in take (end - start) (drop start hist)

-- | Compact everything in @[watermark, windowOffset)@.
-- Returns 'Nothing' when there is no new droppable span.
compactDroppable ::
  Int ->
  Int ->
  [Pin] ->
  Maybe Text ->
  Int ->
  [Turn] ->
  Maybe Int ->
  Maybe (Int, [Pin], Maybe Text, Text)
compactDroppable maxPins maxSummary pins summary watermark hist mWin =
  let offset = windowOffset mWin hist
      spanTurns = droppableSpan mWin watermark hist
   in if null spanTurns
        then Nothing
        else
          let newPins = extractPins spanTurns
              pins' = mergePins maxPins pins newPins
              digest = heuristicSummary spanTurns
              summary' = Just (mergeSummary maxSummary summary digest)
              msg =
                "consolidated "
                  <> T.pack (show (length spanTurns))
                  <> " turns → "
                  <> T.pack (show (length newPins))
                  <> " new pins; watermark="
                  <> T.pack (show offset)
           in Just (offset, pins', summary', msg)

extractPins :: [Turn] -> [Pin]
extractPins turns =
  zipWith assignId [1 :: Int ..] (nubBy sameKey (concatMap fromTurn turns))
  where
    sameKey a b =
      T.toLower a.pinKind == T.toLower b.pinKind
        && T.toLower (T.strip a.pinText) == T.toLower (T.strip b.pinText)
    assignId i p =
      p {pinId = "p" <> T.pack (show i)}
    fromTurn = \case
      TurnUser t ->
        let trimmed = T.strip t
         in [ Pin "" "user" (T.take 200 trimmed)
              | not (T.null trimmed)
            ]
      TurnAssistant _ calls ->
        [ Pin "" "tool" ("called " <> tc.tcName)
          | tc <- calls
        ]
          ++ concatMap (pathsFromJson . tcArguments) calls
      TurnTool results ->
        concatMap
          ( \r ->
              Pin "" "tool" ("result " <> r.trName)
                : pathPinsFromText r.trContent
          )
          results

pathsFromJson :: Aeson.Value -> [Pin]
pathsFromJson = \case
  Aeson.Object o ->
    concatMap
      ( \(k, v) ->
          let key = T.toLower (Key.toText k)
           in case v of
                Aeson.String s
                  | key `elem` ["path", "src", "dst", "file", "glob"] ->
                      [Pin "" "path" (T.take 200 s)]
                  | looksLikePath s -> [Pin "" "path" (T.take 200 s)]
                  | otherwise -> []
                Aeson.Array arr -> concatMap pathsFromJson (V.toList arr)
                Aeson.Object {} -> pathsFromJson v
                _ -> []
      )
      (KM.toList o)
  Aeson.Array arr -> concatMap pathsFromJson (V.toList arr)
  Aeson.String s | looksLikePath s -> [Pin "" "path" (T.take 200 s)]
  _ -> []

pathPinsFromText :: Text -> [Pin]
pathPinsFromText t =
  [ Pin "" "path" (T.take 200 tok)
    | tok <- T.words t,
      looksLikePath tok
  ]

looksLikePath :: Text -> Bool
looksLikePath s =
  let t = T.strip s
   in not (T.null t)
        && T.length t <= 200
        && ( "/" `T.isInfixOf` t
               || "." `T.isInfixOf` t
                 && T.all (\c -> isAlphaNum c || c `elem` ("._-/" :: String)) t
           )

heuristicSummary :: [Turn] -> Text
heuristicSummary turns =
  T.intercalate "\n" (mapMaybe line turns)
  where
    line = \case
      TurnUser t ->
        let u = T.strip t
         in if T.null u then Nothing else Just ("- user: " <> T.take 120 u)
      TurnAssistant t calls ->
        let bits =
              filter
                (not . T.null)
                [ if T.null (T.strip t) then "" else T.take 80 (T.strip t),
                  if null calls
                    then ""
                    else "tools=" <> T.intercalate "," (map (.tcName) calls)
                ]
         in if null bits then Nothing else Just ("- assistant: " <> T.intercalate " " bits)
      TurnTool rs ->
        Just
          ( "- tools: "
              <> T.intercalate ", " [r.trName <> "(" <> T.pack (show (T.length r.trContent)) <> "b)" | r <- rs]
          )

mergePins :: Int -> [Pin] -> [Pin] -> [Pin]
mergePins maxPins existing newPins =
  let combined =
        nubBy
          ( \a b ->
              T.toLower a.pinKind == T.toLower b.pinKind
                && T.toLower (T.strip a.pinText) == T.toLower (T.strip b.pinText)
          )
          (existing ++ newPins)
      numbered = zipWith (\i p -> p {pinId = "p" <> T.pack (show i)}) [1 :: Int ..] combined
   in if maxPins <= 0
        then numbered
        else drop (max 0 (length numbered - maxPins)) numbered

mergeSummary :: Int -> Maybe Text -> Text -> Text
mergeSummary maxChars mold new =
  let merged = case mold of
        Nothing -> new
        Just old
          | T.null (T.strip old) -> new
          | T.null (T.strip new) -> old
          | otherwise -> old <> "\n" <> new
   in if maxChars <= 0 || T.length merged <= maxChars
        then merged
        else T.take maxChars merged <> "\n…"

-- | Pins + optional summary synthetic turn, then L1 windowed (capped) history.
assembleWireTurns ::
  [Pin] ->
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  [Turn] ->
  [Turn]
assembleWireTurns pins summary mWin mMax hist =
  let prefix = assemblePrefix pins summary
      rest = wireTurns mWin mMax hist
   in prefix ++ rest

assemblePrefix :: [Pin] -> Maybe Text -> [Turn]
assemblePrefix pins summary =
  let pinBlock =
        if null pins
          then Nothing
          else
            Just $
              "## Pins\n"
                <> T.intercalate
                  "\n"
                  [ "- [" <> p.pinKind <> "] " <> p.pinText
                    | p <- pins
                  ]
      sumBlock = case summary of
        Just s | not (T.null (T.strip s)) -> Just ("## Earlier context\n" <> s)
        _ -> Nothing
      body = T.intercalate "\n\n" (catMaybes [pinBlock, sumBlock])
   in [TurnUser body | not (T.null body)]

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
