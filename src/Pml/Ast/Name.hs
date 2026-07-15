-- | Identifiers, type names, qualified names, and section slugs.
module Pml.Ast.Name
  ( Ident (..),
    TypeName (..),
    QName (..),
    Slug (..),
    qnameFromParts,
    qnameToText,
    slugToText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

newtype Ident = Ident {unIdent :: Text}
  deriving stock (Eq, Ord, Show)

newtype TypeName = TypeName {unTypeName :: Text}
  deriving stock (Eq, Ord, Show)

-- | Slash-separated module path (@lib/text@). Host paths like @fs.read@ are
-- field projection on an identifier, not a 'QName'.
data QName = QName
  { qnParts :: [Ident]
  }
  deriving stock (Eq, Ord, Show)

newtype Slug = Slug {unSlug :: Text}
  deriving stock (Eq, Ord, Show)

qnameFromParts :: [Text] -> QName
qnameFromParts = QName . map Ident

qnameToText :: QName -> Text
qnameToText (QName parts) = T.intercalate "/" (map unIdent parts)

slugToText :: Slug -> Text
slugToText (Slug s) = s
