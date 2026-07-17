-- | YAML frontmatter for markdown modules (spec §01).
module Hwfl.Parse.Frontmatter
  ( parseFrontmatter,
    parseSkillBlock,
  )
where

import Data.Aeson (Object, Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Yaml qualified as Yaml
import Hwfl.Ast.Module (Frontmatter (..))
import Hwfl.Ast.Name (Ident (..), QName (..), qnameFromParts)
import Hwfl.Ast.Skill
  ( SkillKind (..),
    SkillMeta (..),
    defaultSkillMeta,
    parseSkillKind,
  )
import Hwfl.Ast.Type (Effect, TypeExpr, parseEffectName)
import Hwfl.Parse.Lexer (bundleToDiagnostics)
import Hwfl.Parse.Type (parseTypeText)
import Hwfl.Source (Diagnostic (..), Pos (..), mkDiagnostic)

parseFrontmatter :: FilePath -> Text -> Either [Diagnostic] Frontmatter
parseFrontmatter path yamlText = do
  obj <- parseYamlObject path yamlText
  nameTxt <- requireString path "name" obj
  let fmName = qnameFromText nameTxt
  let fmKind = stringField "kind" obj
  fmInputs <- parseNamedTypes path "inputs" obj
  fmOutputs <- parseNamedTypes path "outputs" obj
  fmEffects <- parseEffects path obj
  fmImports <- parseImports path obj
  fmSkill <- parseOptionalSkillBlock path obj
  pure
    Frontmatter
      { fmName,
        fmKind,
        fmInputs,
        fmOutputs,
        fmEffects,
        fmImports,
        fmSkill
      }

-- | Parse nested @skill:@ when present; missing key → 'Nothing'.
parseOptionalSkillBlock :: FilePath -> Object -> Either [Diagnostic] (Maybe SkillMeta)
parseOptionalSkillBlock path o = case KM.lookup (K.fromText "skill") o of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just _ -> Just <$> parseSkillBlock path o

-- | Parse the nested @skill:@ mapping. Missing @skill:@ defaults to callable.
parseSkillBlock :: FilePath -> Object -> Either [Diagnostic] SkillMeta
parseSkillBlock path o =
  case KM.lookup (K.fromText "skill") o of
    Nothing -> Right defaultSkillMeta
    Just Null -> Right defaultSkillMeta
    Just (Object skillObj) -> parseSkillObject skillObj
    Just _ -> Left [mkDiagnostic path (Pos 1 1) "skill must be a mapping"]
  where
    parseSkillObject skillObj = do
      kind <- parseKind skillObj
      let summary = stringField "summary" skillObj
      tags <- parseTags skillObj
      pure SkillMeta {smKind = kind, smSummary = summary, smTags = tags}
    parseKind skillObj =
      case stringField "kind" skillObj of
        Nothing -> Right SkillCallable
        Just k -> case parseSkillKind k of
          Just sk -> Right sk
          Nothing ->
            Left
              [ mkDiagnostic
                  path
                  (Pos 1 1)
                  ("unknown skill kind '" <> k <> "' (expected 'callable' or 'instruction')")
              ]
    parseTags skillObj = case KM.lookup (K.fromText "tags") skillObj of
      Nothing -> Right []
      Just Null -> Right []
      Just (Array arr) -> Right [t | String t <- toList arr]
      Just _ -> Left [mkDiagnostic path (Pos 1 1) "skill.tags must be a list of strings"]

parseYamlObject :: FilePath -> Text -> Either [Diagnostic] Object
parseYamlObject path yamlText =
  case Yaml.decodeEither' (encodeUtf8 yamlText) of
    Left err ->
      Left [mkDiagnostic path (Pos 1 1) ("invalid frontmatter YAML: " <> T.pack (Yaml.prettyPrintParseException err))]
    Right val -> case val of
      Object o -> Right o
      _ -> Left [mkDiagnostic path (Pos 1 1) "frontmatter must be a YAML mapping"]

stringField :: Text -> Object -> Maybe Text
stringField key o = case KM.lookup (K.fromText key) o of
  Just (String s) -> Just s
  _ -> Nothing

requireString :: FilePath -> Text -> Object -> Either [Diagnostic] Text
requireString path key o = case stringField key o of
  Just s -> Right s
  Nothing -> Left [mkDiagnostic path (Pos 1 1) ("frontmatter missing string field: " <> key)]

parseNamedTypes :: FilePath -> Text -> Object -> Either [Diagnostic] [(Ident, TypeExpr)]
parseNamedTypes path key o = case KM.lookup (K.fromText key) o of
  Nothing -> Right []
  Just Null -> Right []
  Just (Object fields) ->
    traverse (parseField path) (KM.toList fields)
  Just _ ->
    Left [mkDiagnostic path (Pos 1 1) (key <> " must be a mapping of name: Type")]

parseField :: FilePath -> (K.Key, Value) -> Either [Diagnostic] (Ident, TypeExpr)
parseField path (k, v) = case v of
  String tyTxt -> do
    ty <- parseTypeOrDiag path tyTxt
    pure (Ident (K.toText k), ty)
  _ ->
    Left [mkDiagnostic path (Pos 1 1) ("type for " <> K.toText k <> " must be a string")]

parseTypeOrDiag :: FilePath -> Text -> Either [Diagnostic] TypeExpr
parseTypeOrDiag path tyTxt =
  case parseTypeText path tyTxt of
    Left bundle -> Left (bundleToDiagnostics path bundle)
    Right t -> Right t

parseEffects :: FilePath -> Object -> Either [Diagnostic] (Maybe [Effect])
parseEffects path o = case KM.lookup (K.fromText "effects") o of
  Nothing -> Right Nothing
  Just Null -> Right Nothing
  Just (Array arr) -> Just <$> traverse (parseEffect path) (toList arr)
  Just _ -> Left [mkDiagnostic path (Pos 1 1) "effects must be a list of effect names"]

parseEffect :: FilePath -> Value -> Either [Diagnostic] Effect
parseEffect path = \case
  String s -> case parseEffectName s of
    Just e -> Right e
    Nothing -> Left [mkDiagnostic path (Pos 1 1) ("unknown effect: " <> s)]
  _ -> Left [mkDiagnostic path (Pos 1 1) "effect entries must be strings"]

parseImports :: FilePath -> Object -> Either [Diagnostic] [QName]
parseImports path o = case KM.lookup (K.fromText "imports") o of
  Nothing -> Right []
  Just Null -> Right []
  Just (Array arr) -> traverse (parseImport path) (toList arr)
  Just _ -> Left [mkDiagnostic path (Pos 1 1) "imports must be a list of qnames"]

parseImport :: FilePath -> Value -> Either [Diagnostic] QName
parseImport path = \case
  String s -> Right (qnameFromText s)
  _ -> Left [mkDiagnostic path (Pos 1 1) "import entries must be strings"]

qnameFromText :: Text -> QName
qnameFromText t = qnameFromParts (T.splitOn "/" t)
