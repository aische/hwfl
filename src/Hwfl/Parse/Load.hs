-- | Load a markdown module: frontmatter + sections + primary @hwfl@ fence AST
-- (or prose-only instruction skill under @skills/@).
module Hwfl.Parse.Load
  ( loadModule,
    loadModuleText,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (guard)
import Data.List (dropWhileEnd)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Decl (ModuleBody (..))
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..), SchemaDoc (..), Section (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Parse.Frontmatter (parseFrontmatter)
import Hwfl.Parse.Lexer (bundleToDiagnostics)
import Hwfl.Parse.Markdown (MarkdownFile (..), MdFence (..), parseMarkdown)
import Hwfl.Parse.Module (parseModuleBodyFromLine)
import Hwfl.Parse.Section (buildSections)
import Hwfl.Source (Diagnostic (..), Pos (..), mkDiagnostic)

loadModule :: FilePath -> IO (Either [Diagnostic] LoadedModule)
loadModule path = do
  src <- TIO.readFile path
  pure (loadModuleText path src)

loadModuleText :: FilePath -> Text -> Either [Diagnostic] LoadedModule
loadModuleText path src = do
  md <- parseMarkdown path src
  fmText <- case md.mdFrontmatter of
    Just t -> Right t
    Nothing -> Left [mkDiagnostic path (Pos 1 1) "module requires YAML frontmatter"]
  fm <- parseFrontmatter path fmText
  let prose = proseBodyAfterFrontmatter md.mdFrontmatter md.mdLines
      sections = buildSections md.mdLines md.mdHeadings md.mdFences
      schemaDocs = mapMaybe schemaDocSection sections
  case fmap smKind fm.fmSkill of
    Just SkillInstruction -> do
      ensureNoHwflFence path md.mdFences
      ensureNonEmptyInstruction path prose
      pure
        LoadedModule
          { lmPath = path,
            lmFrontmatter = fm,
            lmSections = sections,
            lmSchemaDocs = schemaDocs,
            lmBody = ModuleBody [] Nothing,
            lmProseBody = prose
          }
    _ -> do
      fence <- exactlyOneHwflFence path md.mdFences
      -- mfStartLine is the opening ``` line; content starts on the next line.
      let contentStartLine = fence.mfStartLine + 1
      body <- case parseModuleBodyFromLine contentStartLine path fence.mfContent of
        Left bundle -> Left (bundleToDiagnostics path bundle)
        Right b -> Right b
      pure
        LoadedModule
          { lmPath = path,
            lmFrontmatter = fm,
            lmSections = sections,
            lmSchemaDocs = schemaDocs,
            lmBody = body,
            lmProseBody = prose
          }

-- | Markdown body after YAML frontmatter.
proseBodyAfterFrontmatter :: Maybe Text -> [Text] -> Text
proseBodyAfterFrontmatter mFm lines_ =
  T.strip $
    case mFm of
      Nothing -> T.unlines lines_
      Just _ -> bodyAfterFence lines_
  where
    bodyAfterFence lns = case lns of
      (_ : rest) ->
        case break (\l -> T.strip l == "---") rest of
          (_, _ : bodyLines) -> T.unlines bodyLines
          _ -> ""
      [] -> ""

ensureNoHwflFence :: FilePath -> [MdFence] -> Either [Diagnostic] ()
ensureNoHwflFence path fences =
  case filter isHwfl fences of
    [] -> Right ()
    _ ->
      Left
        [ mkDiagnostic
            path
            (Pos 1 1)
            "instruction skill must not contain a ```hwfl fence"
        ]
  where
    isHwfl f =
      case T.words (T.strip f.mfInfo) of
        ("hwfl" : _) -> True
        _ -> False

ensureNonEmptyInstruction :: FilePath -> Text -> Either [Diagnostic] ()
ensureNonEmptyInstruction path body =
  if T.null (T.strip body)
    then Left [mkDiagnostic path (Pos 1 1) "instruction skill body must be non-empty"]
    else Right ()

exactlyOneHwflFence :: FilePath -> [MdFence] -> Either [Diagnostic] MdFence
exactlyOneHwflFence path fences =
  case filter isHwfl fences of
    [f] -> Right f
    [] -> Left [mkDiagnostic path (Pos 1 1) "module requires exactly one ```hwfl fence"]
    _ -> Left [mkDiagnostic path (Pos 1 1) "module has multiple ```hwfl fences (v0 allows one)"]
  where
    isHwfl f =
      case T.words (T.strip f.mfInfo) of
        ("hwfl" : _) -> True
        _ -> False

schemaDocSection :: Section -> Maybe SchemaDoc
schemaDocSection sec = do
  tyName <- schemaTitleTypeName sec.secTitle
  pure
    SchemaDoc
      { sdTypeName = tyName,
        sdFieldDocs = parseFieldDocs sec.secBody
      }

schemaTitleTypeName :: Text -> Maybe TypeName
schemaTitleTypeName title = case T.words (T.strip title) of
  ["schema", typeName] -> Just (TypeName typeName)
  _ -> Nothing

parseFieldDocs :: Text -> [(Ident, Text)]
parseFieldDocs body = go [] Nothing (T.lines body)
  where
    go acc Nothing [] = reverse acc
    go acc (Just (name, descLines)) [] =
      reverse ((Ident name, finishDesc descLines) : acc)
    go acc current (line : rest) =
      case parseBullet line of
        Just (name, desc) ->
          let acc' = flush acc current
           in go acc' (Just (name, [desc])) rest
        Nothing -> case current of
          Just (name, descLines) ->
            go acc (Just (name, descLines ++ [T.strip line])) rest
          Nothing ->
            go acc Nothing rest

    flush acc = \case
      Just (name, descLines) -> (Ident name, finishDesc descLines) : acc
      Nothing -> acc

    finishDesc =
      T.strip
        . T.intercalate "\n"
        . dropWhileEnd T.null
        . dropWhile T.null

parseBullet :: Text -> Maybe (Text, Text)
parseBullet line = do
  rest0 <- stripBullet (T.stripStart line)
  let (name0, desc0) = T.breakOn ":" rest0
  guard (not (T.null desc0))
  let name = stripCodeTicks (T.strip name0)
  guard (not (T.null name))
  pure (name, T.strip (T.drop 1 desc0))
  where
    stripBullet t =
      T.stripPrefix "- " t
        <|> T.stripPrefix "* " t
        <|> T.stripPrefix "-\t" t
        <|> T.stripPrefix "*\t" t
    stripCodeTicks t =
      fromMaybe t $
        T.stripPrefix "`" t >>= \inner -> T.stripSuffix "`" inner
