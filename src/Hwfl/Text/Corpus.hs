-- | Pure text corpus utilities for semantic review (hwfi Text.Corpus port, slimmed).
module Hwfl.Text.Corpus
  ( TextMetrics (..),
    textMetrics,
    textSimilarity,
    splitSentences,
    textContains,
    textTrim,
    textStartsWith,
    textNormalizeToken,
    textIsQname,
  )
where

import Data.Char (isAlphaNum, isAscii)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

data TextMetrics = TextMetrics
  { tmChars :: !Int,
    tmTokens :: !Int,
    tmLines :: !Int,
    tmShannonEntropy :: !Double,
    -- | Unique-char ratio (zlib-free stand-in for compression signal).
    tmUniqueness :: !Double
  }
  deriving stock (Eq, Show)

textMetrics :: Text -> TextMetrics
textMetrics text =
  TextMetrics
    { tmChars = T.length text,
      tmTokens = length (T.words text),
      tmLines = length (T.lines text),
      tmShannonEntropy = shannonEntropy (T.words text),
      tmUniqueness = uniquenessRatio text
    }

textSimilarity :: Text -> Text -> Double
textSimilarity left right = jaccardSet (wordUnigrams left) (wordUnigrams right)

textContains :: Text -> Text -> Bool
textContains hay needle = needle `T.isInfixOf` hay

textTrim :: Text -> Text
textTrim = T.strip

textStartsWith :: Text -> Text -> Bool
textStartsWith s prefix = prefix `T.isPrefixOf` s

-- | Strip whitespace and wrapping punctuation / backticks (stable fixed point).
textNormalizeToken :: Text -> Text
textNormalizeToken = go . T.strip
  where
    wrap = "`\"'.,;:!?()[]{}" :: [Char]
    go t =
      let t' = T.dropWhileEnd (`elem` wrap) (T.dropWhile (`elem` wrap) t)
       in if t' == t then t else go t'

-- | Conservative module qname shape: @root/seg(/seg)*@ with known roots.
-- Rejects paths (@/tmp/…@), URLs, globs, and English slash-compounds
-- (@stdout/stderr@, @language/toolchain@).
textIsQname :: Text -> Bool
textIsQname raw =
  let t = textNormalizeToken raw
      roots =
        Set.fromList
          [ "workflows",
            "lib",
            "skills",
            "tools",
            "types",
            "builtin"
          ]
   in case T.splitOn "/" t of
        parts@(root : _ : _) ->
          not (T.null t)
            && not ("*" `T.isInfixOf` t)
            && not ("http" `T.isInfixOf` T.toLower t)
            && Set.member root roots
            && all isQnameSegment parts
        _ -> False

isQnameSegment :: Text -> Bool
isQnameSegment s =
  case T.uncons s of
    Just (c, rest) ->
      isAscii c
        && (isAlphaNum c || c == '_')
        && T.all (\x -> isAscii x && (isAlphaNum x || x == '_' || x == '-')) rest
    Nothing -> False

splitSentences :: Text -> [Text]
splitSentences text =
  filter (not . T.null . T.strip) (map T.strip (consume (T.unpack text) [] []))
  where
    punct = ['.', '!', '?'] :: [Char]
    space = [' ', '\n', '\t'] :: [Char]
    consume [] acc cur =
      let sent = T.pack (reverse cur)
       in if not (null acc)
            then reverse acc
            else [T.strip sent | not (T.null (T.strip sent))]
    consume (c : cs) acc cur
      | c `elem` punct && (null cs || head cs `elem` space) =
          let sent = T.pack (reverse (c : cur))
              rest = dropWhile (`elem` space) cs
           in if T.null (T.strip sent)
                then consume rest acc []
                else consume rest (sent : acc) []
      | otherwise = consume cs acc (c : cur)

shannonEntropy :: [Text] -> Double
shannonEntropy [] = 0
shannonEntropy tokens =
  let total = fromIntegral (length tokens)
      counts = Map.fromListWith ((+) :: Int -> Int -> Int) [(t, 1) | t <- tokens]
   in negate (sum [p * logBase 2 p | c <- Map.elems counts, let p = fromIntegral c / total])

uniquenessRatio :: Text -> Double
uniquenessRatio text
  | T.null text = 1
  | otherwise =
      fromIntegral (Set.size (Set.fromList (T.unpack text)))
        / fromIntegral (T.length text)

jaccardSet :: Set.Set Text -> Set.Set Text -> Double
jaccardSet a b
  | Set.null a && Set.null b = 1
  | otherwise =
      let inter = Set.size (Set.intersection a b)
          union = Set.size (Set.union a b)
       in if union == 0 then 0 else fromIntegral inter / fromIntegral union

wordUnigrams :: Text -> Set.Set Text
wordUnigrams = Set.fromList . T.words
