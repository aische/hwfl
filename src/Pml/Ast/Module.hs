-- | Loaded markdown module surface (L1), before/with kernel AST.
module Pml.Ast.Module
  ( Frontmatter (..),
    Section (..),
    SchemaDoc (..),
    LoadedModule (..),
  )
where

import Data.Text (Text)
import Pml.Ast.Decl (ModuleBody)
import Pml.Ast.Name (Ident, QName, Slug, TypeName)
import Pml.Ast.Type (Effect, TypeExpr)

data Frontmatter = Frontmatter
  { fmName :: QName,
    fmKind :: Maybe Text,
    fmInputs :: [(Ident, TypeExpr)],
    fmOutputs :: [(Ident, TypeExpr)],
    fmEffects :: Maybe [Effect],
    fmImports :: [QName]
  }
  deriving stock (Eq, Show)

data Section = Section
  { secSlug :: Slug,
    secLevel :: Int,
    secTitle :: Text,
    secBody :: Text
  }
  deriving stock (Eq, Show)

data SchemaDoc = SchemaDoc
  { sdTypeName :: TypeName,
    sdFieldDocs :: [(Ident, Text)]
  }
  deriving stock (Eq, Show)

data LoadedModule = LoadedModule
  { lmPath :: FilePath,
    lmFrontmatter :: Frontmatter,
    lmSections :: [Section],
    lmSchemaDocs :: [SchemaDoc],
    lmBody :: ModuleBody
  }
  deriving stock (Eq, Show)
