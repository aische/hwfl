-- | Pure text corpus utilities for semantic review (hwfi Text.Corpus port, slimmed).
module Pml.Text.Corpus
  ( TextMetrics (..),
    textMetrics,
    textSimilarity,
    splitSentences,
    textContains,
  )
where

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
