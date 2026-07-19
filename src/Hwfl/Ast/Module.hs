-- | Loaded markdown module surface (L1), before/with kernel AST.
module Hwfl.Ast.Module
  ( Frontmatter (..),
    ExampleInputs (..),
    Section (..),
    SchemaDoc (..),
    LoadedModule (..),
  )
where

import Data.Aeson (Object)
import Data.Text (Text)
import Hwfl.Ast.Decl (ModuleBody)
import Hwfl.Ast.Name (Ident, QName, Slug, TypeName)
import Hwfl.Ast.Skill (SkillMeta)
import Hwfl.Ast.Type (Effect, TypeExpr)

-- | Authoring / tooling sample run inputs (frontmatter @examples@).
-- Not a runtime binding; values are JSON-shaped (untyped vs TypeExpr for now).
data ExampleInputs = ExampleInputs
  { eiName :: Maybe Text,
    eiInputs :: Object
  }
  deriving stock (Eq, Show)

data Frontmatter = Frontmatter
  { fmName :: QName,
    fmKind :: Maybe Text,
    fmInputs :: [(Ident, TypeExpr)],
    fmOutputs :: [(Ident, TypeExpr)],
    fmEffects :: Maybe [Effect],
    fmImports :: [QName],
    -- | Nested @skill:@ block when present (skills-plan §4.1).
    fmSkill :: Maybe SkillMeta,
    -- | Optional documented example run inputs for tooling / UI.
    fmExamples :: [ExampleInputs]
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
    lmBody :: ModuleBody,
    -- | Markdown after frontmatter (instruction skill body / summary fallback).
    lmProseBody :: Text
  }
  deriving stock (Eq, Show)
