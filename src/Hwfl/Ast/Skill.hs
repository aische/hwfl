-- | Skill kinds and frontmatter metadata (skills-plan §3–§4).
module Hwfl.Ast.Skill
  ( SkillKind (..),
    SkillMeta (..),
    skillKindText,
    parseSkillKind,
    defaultSkillMeta,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | Callable tools vs prose-only instruction guides.
data SkillKind = SkillCallable | SkillInstruction
  deriving stock (Eq, Show)

data SkillMeta = SkillMeta
  { smKind :: SkillKind,
    smSummary :: Maybe Text,
    smTags :: [Text]
  }
  deriving stock (Eq, Show)

defaultSkillMeta :: SkillMeta
defaultSkillMeta = SkillMeta SkillCallable Nothing []

skillKindText :: SkillKind -> Text
skillKindText = \case
  SkillCallable -> "callable"
  SkillInstruction -> "instruction"

parseSkillKind :: Text -> Maybe SkillKind
parseSkillKind t = case T.toLower (T.strip t) of
  "callable" -> Just SkillCallable
  "instruction" -> Just SkillInstruction
  _ -> Nothing
