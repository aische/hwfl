-- | Heading slugify and section body extraction (spec §01).
module Hwfl.Parse.Section
  ( computeSlug,
    buildSections,
    SlugIssue (..),
    headingSlugIssues,
    formatSlugIssue,
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (Section (..))
import Hwfl.Ast.Name (Slug (..), slugToText)
import Hwfl.Parse.Markdown (MdFence (..), MdHeading (..))

-- | Lowercase, spaces to @-@, strip non @[a-z0-9-]@, collapse hyphens.
computeSlug :: Text -> Slug
computeSlug t =
  Slug $
    T.intercalate "-" $
      filter (not . T.null) $
        T.splitOn "-" $
          T.filter ok $
            T.map spaceToDash $
              T.toLower t
  where
    spaceToDash c = if c == ' ' then '-' else c
    ok c = isAsciiLower c || isDigit c || c == '-'

-- | Empty or colliding H2/H3 slugs (L-7).
data SlugIssue
  = EmptySlug
      { siTitle :: Text,
        siLine :: Int
      }
  | DuplicateSlug
      { siSlug :: Slug,
        siOccurrences :: [(Text, Int)]
      }
  deriving stock (Eq, Show)

-- | Collect empty and duplicate slug issues for H2/H3 headings (document order).
headingSlugIssues :: [MdHeading] -> [SlugIssue]
headingSlugIssues headings =
  let hs = [h | h <- headings, mhLevel h == 2 || mhLevel h == 3]
      emptied =
        [ EmptySlug (mhText h) (mhStartLine h)
          | h <- hs,
            T.null (slugToText (computeSlug (mhText h)))
        ]
      bySlug =
        Map.fromListWith (++) $
          [ (computeSlug (mhText h), [(mhText h, mhStartLine h)])
            | h <- hs,
              not (T.null (slugToText (computeSlug (mhText h))))
          ]
      dups =
        [ DuplicateSlug slug (sortOn snd occs)
          | (slug, occs) <- Map.toList bySlug,
            length occs > 1
        ]
   in emptied ++ sortOn dupLine dups
  where
    dupLine (DuplicateSlug _ ((_, line) : _)) = line
    dupLine _ = 0

formatSlugIssue :: SlugIssue -> Text
formatSlugIssue = \case
  EmptySlug title _ ->
    "empty section slug for heading " <> quote title
  DuplicateSlug slug occs ->
    "duplicate section slug "
      <> quote (slugToText slug)
      <> ": headings "
      <> T.intercalate " and " (map (quote . fst) occs)
  where
    quote t = "\"" <> t <> "\""

-- | Build H2/H3 sections. Bodies are raw markdown between the heading and the
-- next heading of equal or higher level, excluding fenced @hwfl@ blocks.
buildSections :: [Text] -> [MdHeading] -> [MdFence] -> [Section]
buildSections srcLines headings fences =
  [ mkSection i h
    | (i, h) <- indexed,
      mhLevel h == 2 || mhLevel h == 3
  ]
  where
    indexed = zip [0 ..] headings
    total = length headings
    hwflFences = filter isHwflFence fences

    mkSection i h =
      Section
        { secSlug = computeSlug (mhText h),
          secLevel = mhLevel h,
          secTitle = mhText h,
          secBody = T.strip (sliceWithoutFences srcLines hwflFences contentStart contentEnd)
        }
      where
        contentStart = mhEndLine h + 1
        contentEnd = case laterSameOrHigher i h of
          (nh : _) -> mhStartLine nh - 1
          [] -> length srcLines

    laterSameOrHigher i h =
      [ headings !! j
        | j <- [i + 1 .. total - 1],
          mhLevel (headings !! j) <= mhLevel h
      ]

isHwflFence :: MdFence -> Bool
isHwflFence f =
  case T.words (T.strip f.mfInfo) of
    ("hwfl" : _) -> True
    _ -> False

sliceWithoutFences :: [Text] -> [MdFence] -> Int -> Int -> Text
sliceWithoutFences srcLines fences from to =
  T.intercalate "\n" $
    [ srcLines !! (i - 1)
      | i <- [lo .. hi],
        not (any (covers i) fences)
    ]
  where
    lo = max 1 from
    hi = min (length srcLines) to
    covers i f = i >= f.mfStartLine && i <= f.mfEndLine
