-- | Check-time skill catalog (skills-plan §4). Built from @skills/*.md@ and
-- consumed by @skill.discover@ / @skill.load@.
module Hwfl.SkillCatalog
  ( SkillEntry (..),
    SkillCatalog (..),
    SkillPolicy (..),
    defaultSkillPolicy,
    emptySkillCatalog,
    buildSkillCatalog,
    lookupSkillEntry,
    discoverSkills,
    summaryFallback,
    isSkillQName,
    skillMetaForModule,
  )
where

import Data.Aeson (FromJSON (..), withObject, (.:?))
import Data.Aeson.Types ((.!=))
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (Ident (..), QName (..), qnameToText)
import Hwfl.Ast.Skill
  ( SkillKind (..),
    SkillMeta (..),
    defaultSkillMeta,
    parseSkillKind,
  )
import Hwfl.Ast.Type (Effect (..), TypeExpr (..))

-- | Optional @project.json@ @skills@ stanza limits (skills-plan §4.2).
data SkillPolicy = SkillPolicy
  { spMaxCallableLoads :: Int,
    spMaxInstructionLoads :: Int,
    spMaxInstructionChars :: Int
  }
  deriving stock (Eq, Show)

defaultSkillPolicy :: SkillPolicy
defaultSkillPolicy =
  SkillPolicy
    { spMaxCallableLoads = 20,
      spMaxInstructionLoads = 5,
      spMaxInstructionChars = 12000
    }

instance FromJSON SkillPolicy where
  parseJSON = withObject "skills" $ \o ->
    SkillPolicy
      <$> o .:? "max_callable_loads" .!= spMaxCallableLoads defaultSkillPolicy
      <*> o .:? "max_instruction_loads" .!= spMaxInstructionLoads defaultSkillPolicy
      <*> o .:? "max_instruction_chars" .!= spMaxInstructionChars defaultSkillPolicy

-- | One catalog row returned by @skill.discover@ (metadata only).
data SkillEntry = SkillEntry
  { seId :: QName,
    seKind :: SkillKind,
    seSummary :: Text,
    seTags :: [Text],
    sePath :: FilePath,
    seChecked :: Bool,
    seAgentEligible :: Bool,
    -- | Full markdown body for instruction skills (never exposed via discover).
    seBody :: Maybe Text
  }
  deriving stock (Eq, Show)

data SkillCatalog = SkillCatalog
  { scPolicy :: SkillPolicy,
    scEntries :: Map QName SkillEntry
  }
  deriving stock (Eq, Show)

emptySkillCatalog :: SkillPolicy -> SkillCatalog
emptySkillCatalog policy = SkillCatalog policy Map.empty

lookupSkillEntry :: QName -> SkillCatalog -> Maybe SkillEntry
lookupSkillEntry q cat = Map.lookup q (scEntries cat)

isSkillQName :: QName -> Bool
isSkillQName q = case qnParts q of
  Ident "skills" : _ -> True
  _ -> False

-- | Effective skill meta for a module under @skills/@ (default callable).
skillMetaForModule :: LoadedModule -> SkillMeta
skillMetaForModule m =
  fromMaybe defaultSkillMeta m.lmFrontmatter.fmSkill

-- | Build the catalog after project check. @checked@ are modules that passed
-- typecheck (callables) or instruction validation.
buildSkillCatalog ::
  SkillPolicy ->
  Map QName LoadedModule ->
  Set QName ->
  SkillCatalog
buildSkillCatalog policy modules checked =
  SkillCatalog policy (Map.fromList entries)
  where
    entries =
      mapMaybe entryFor (Map.toList modules)
    entryFor (q, m)
      | not (isSkillQName q) = Nothing
      | otherwise =
          let meta = skillMetaForModule m
              kind = meta.smKind
              body = m.lmProseBody
              summary =
                fromMaybe (summaryFallback body) meta.smSummary
           in Just
                ( q,
                  SkillEntry
                    { seId = q,
                      seKind = kind,
                      seSummary = summary,
                      seTags = meta.smTags,
                      sePath = m.lmPath,
                      seChecked = q `Set.member` checked,
                      seAgentEligible = callableEligible kind q m,
                      seBody =
                        if kind == SkillInstruction
                          then Just body
                          else Nothing
                    }
                )
    callableEligible SkillInstruction _ _ = False
    callableEligible SkillCallable q m =
      q `Set.member` checked
        && not (hasMetaEffect m.lmFrontmatter)
        && not (hasSecretInputs m.lmFrontmatter)

hasMetaEffect :: Frontmatter -> Bool
hasMetaEffect fm = case fm.fmEffects of
  Just es -> EffMeta `elem` es
  Nothing -> False

hasSecretInputs :: Frontmatter -> Bool
hasSecretInputs fm =
  any (isSecretType . snd) fm.fmInputs
  where
    isSecretType = \case
      TSecret _ -> True
      _ -> False

-- | Filter and rank catalog entries for @skill.discover@.
discoverSkills :: SkillCatalog -> Text -> [Text] -> Int -> [SkillEntry]
discoverSkills cat query kinds limit =
  take effectiveLimit ranked
  where
    effectiveLimit = if limit <= 0 then 20 else limit
    qLower = T.toLower (T.strip query)
    kindFilter = mapMaybe parseSkillKind kinds
    matched =
      filter matchesKind $
        filter matchesQuery $
          Map.elems (scEntries cat)
    matchesKind e =
      null kindFilter || seKind e `elem` kindFilter
    matchesQuery e
      | T.null qLower = True
      | otherwise =
          textHits qLower (qnameToText (seId e))
            || textHits qLower (seSummary e)
            || any (tagHits qLower) (seTags e)
    ranked =
      sortOn
        ( \e ->
            ( Down (scoreTag e),
              Down (scoreSummary e),
              Down (scoreId e),
              qnameToText (seId e)
            )
        )
        matched
    scoreTag e =
      if any (tagHits qLower) (seTags e) then (1 :: Int) else 0
    scoreSummary e =
      if textHits qLower (seSummary e) then (1 :: Int) else 0
    scoreId e =
      if textHits qLower (qnameToText (seId e)) then (1 :: Int) else 0

-- | Case-insensitive substring match in either direction.
textHits :: Text -> Text -> Bool
textHits q t =
  let ql = T.toLower q
      tl = T.toLower t
   in ql `T.isInfixOf` tl || tl `T.isInfixOf` ql

-- | Match a query (including individual words) against a tag.
tagHits :: Text -> Text -> Bool
tagHits q tag =
  let tl = T.toLower tag
   in textHits q tl || any ((`textHits` tl) . T.toLower) (T.words q)

-- | First non-empty, non-fence body line when @skill.summary@ is absent.
summaryFallback :: Text -> Text
summaryFallback body =
  fromMaybe "" $
    find isGood (map T.strip (T.lines body))
  where
    isGood l = not (T.null l) && not ("```" `T.isPrefixOf` l)
