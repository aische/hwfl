-- | Identifiers, type names, qualified names, and section slugs.
module Hwfl.Ast.Name
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
  deriving stock (Eq, Ord, Show, Read)

newtype TypeName = TypeName {unTypeName :: Text}
  deriving stock (Eq, Ord, Show, Read)

-- | Slash-separated module path (@lib/text@). Host paths like @fs.read@ are
-- field projection on an identifier, not a 'QName'.
newtype QName = QName
  { qnParts :: [Ident]
  }
  deriving stock (Eq, Ord, Show, Read)

newtype Slug = Slug {unSlug :: Text}
  deriving stock (Eq, Ord, Show, Read)

qnameFromParts :: [Text] -> QName
qnameFromParts = QName . map Ident

qnameToText :: QName -> Text
qnameToText (QName parts) = T.intercalate "/" (map unIdent parts)

slugToText :: Slug -> Text
slugToText (Slug s) = s
