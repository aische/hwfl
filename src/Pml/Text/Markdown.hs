-- | Pure markdown section extraction for in-language review (reuses loader logic).
module Pml.Text.Markdown
  ( MdSection (..),
    extractSections,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Module (Section (..))
import Pml.Ast.Name (slugToText)
import Pml.Parse.Markdown (MarkdownFile (..), parseMarkdown)
import Pml.Parse.Section (buildSections)
import Pml.Source (Diagnostic (..))

data MdSection = MdSection
  { msSlug :: Text,
    msTitle :: Text,
    msBody :: Text
  }
  deriving stock (Eq, Show)

-- | Parse markdown text into H2/H3 sections (pml fences stripped from bodies).
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
