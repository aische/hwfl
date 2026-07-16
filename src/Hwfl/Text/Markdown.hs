-- | Pure markdown section extraction for in-language review (reuses loader logic).
module Hwfl.Text.Markdown
  ( MdSection (..),
    extractSections,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (Section (..))
import Hwfl.Ast.Name (slugToText)
import Hwfl.Parse.Markdown (MarkdownFile (..), parseMarkdown)
import Hwfl.Parse.Section (buildSections)
import Hwfl.Source (Diagnostic (..))

data MdSection = MdSection
  { msSlug :: Text,
    msTitle :: Text,
    msBody :: Text
  }
  deriving stock (Eq, Show)

-- | Parse markdown text into H2/H3 sections (hwfl fences stripped from bodies).
extractSections :: Text -> Either Text [MdSection]
extractSections src = case parseMarkdown "<md>" src of
  Left diags -> Left (T.intercalate "; " (map diagMessage diags))
  Right md ->
    let secs = buildSections (mdLines md) (mdHeadings md) (mdFences md)
     in Right
          [ MdSection
              { msSlug = slugToText s.secSlug,
                msTitle = s.secTitle,
                msBody = s.secBody
              }
            | s <- secs
          ]
