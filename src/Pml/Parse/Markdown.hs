-- | Markdown structural parse: frontmatter split, headings, @pml@ fences.
module Pml.Parse.Markdown
  ( MarkdownFile (..),
    MdHeading (..),
    MdFence (..),
    parseMarkdown,
    sliceLines,
  )
where

import Commonmark
  ( HasAttributes (..),
    IsBlock (..),
    IsInline (..),
    ParseError,
    Rangeable (..),
    SourceRange (..),
    commonmark,
    sourceColumn,
    sourceLine,
    sourceName,
  )
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Source (Diagnostic (..), Pos (..))
import Text.Parsec.Error (errorMessages, errorPos, messageString)

data MdHeading = MdHeading
  { mhLevel :: Int,
    mhText :: Text,
    mhStartLine :: Int,
    mhEndLine :: Int
  }
  deriving stock (Eq, Show)

data MdFence = MdFence
  { mfInfo :: Text,
    mfContent :: Text,
    mfStartLine :: Int,
    mfEndLine :: Int
  }
  deriving stock (Eq, Show)

data MarkdownFile = MarkdownFile
  { mdFrontmatter :: Maybe Text,
    mdHeadings :: [MdHeading],
    mdFences :: [MdFence],
    mdLines :: [Text]
  }
  deriving stock (Eq, Show)

parseMarkdown :: FilePath -> Text -> Either [Diagnostic] MarkdownFile
parseMarkdown path src =
  let srcLines = T.splitOn "\n" src
      (mfm, maskedBody) = splitFrontmatter srcLines
   in case commonmark path maskedBody :: Either ParseError Blocks of
        Left e -> Left [cmErrorToDiag path e]
        Right (Blocks items) ->
          Right
            MarkdownFile
              { mdFrontmatter = mfm,
                mdHeadings = mapMaybe toHeading items,
                mdFences = mapMaybe toFence items,
                mdLines = srcLines
              }
  where
    toHeading (BHeading lvl txt r) = do
      sl <- rangeStartLine r
      let el = fromMaybe sl (rangeEndLine r)
      Just (MdHeading lvl (T.strip txt) sl el)
    toHeading _ = Nothing

    toFence (BCode info content r) = do
      sl <- rangeStartLine r
      let el = fromMaybe sl (rangeEndLine r)
      Just (MdFence info content sl el)
    toFence _ = Nothing

sliceLines :: [Text] -> Int -> Int -> Text
sliceLines srcLines from to =
  T.intercalate "\n" (take (hi - lo + 1) (drop (lo - 1) srcLines))
  where
    lo = max 1 from
    hi = min (length srcLines) to

splitFrontmatter :: [Text] -> (Maybe Text, Text)
splitFrontmatter allLines =
  case allLines of
    (l0 : rest)
      | isFence l0 ->
          case break isFence rest of
            (fmLines, closeLine : bodyLines)
              | isFence closeLine ->
                  let blanks = replicate (length fmLines + 2) ""
                   in (Just (T.intercalate "\n" fmLines), T.intercalate "\n" (blanks <> bodyLines))
            _ -> (Nothing, T.intercalate "\n" allLines)
    _ -> (Nothing, T.intercalate "\n" allLines)
  where
    isFence l = T.strip l == "---"

rangeStartLine :: SourceRange -> Maybe Int
rangeStartLine (SourceRange xs) = case xs of
  [] -> Nothing
  ((s, _) : _) -> Just (sourceLine s)

rangeEndLine :: SourceRange -> Maybe Int
rangeEndLine (SourceRange xs) = case xs of
  [] -> Nothing
  _ -> Just (sourceLine (snd (last xs)))

cmErrorToDiag :: FilePath -> ParseError -> Diagnostic
cmErrorToDiag path e =
  Diagnostic
    { diagPath = if null (sourceName pos) then path else sourceName pos,
      diagPos = Pos (sourceLine pos) (sourceColumn pos),
      diagMessage = "markdown parse error: " <> msg
    }
  where
    pos = errorPos e
    msg =
      let parts = filter (not . null) (map messageString (errorMessages e))
       in if null parts then "invalid markdown" else T.pack (unwords parts)

-- commonmark targets --------------------------------------------------------

newtype Inlines = Inlines {inlineText :: Text}
  deriving stock (Show)
  deriving newtype (Semigroup, Monoid)

instance Rangeable Inlines where
  ranged _ = id

instance HasAttributes Inlines where
  addAttributes _ = id

instance IsInline Inlines where
  lineBreak = Inlines " "
  softBreak = Inlines " "
  str = Inlines
  entity = Inlines
  escapedChar c = Inlines (T.singleton c)
  emph = id
  strong = id
  link _ _ x = x
  image _ _ x = x
  code = Inlines
  rawInline _ = Inlines

data BlockItem
  = BHeading Int Text SourceRange
  | BCode Text Text SourceRange
  deriving stock (Show)

newtype Blocks = Blocks {blockItems :: [BlockItem]}
  deriving stock (Show)
  deriving newtype (Semigroup, Monoid)

instance Rangeable Blocks where
  ranged r (Blocks items) = Blocks (map setRange items)
    where
      setRange (BHeading l t _) = BHeading l t r
      setRange (BCode i c _) = BCode i c r

instance HasAttributes Blocks where
  addAttributes _ = id

instance IsBlock Inlines Blocks where
  paragraph _ = mempty
  plain _ = mempty
  thematicBreak = mempty
  blockQuote b = b
  codeBlock info content = Blocks [BCode info content (SourceRange [])]
  heading level il = Blocks [BHeading level (inlineText il) (SourceRange [])]
  rawBlock _ _ = mempty
  referenceLinkDefinition _ _ = mempty
  list _ _ = mconcat
