-- | Load a markdown module: frontmatter + sections + primary @pml@ fence AST.
module Pml.Parse.Load
  ( loadModule,
    loadModuleText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Pml.Ast.Module (LoadedModule (..))
import Pml.Parse.Frontmatter (parseFrontmatter)
import Pml.Parse.Lexer (bundleToDiagnostics)
import Pml.Parse.Markdown (MarkdownFile (..), MdFence (..), parseMarkdown)
import Pml.Parse.Module (parseModuleBody)
import Pml.Parse.Section (buildSections)
import Pml.Source (Diagnostic (..), Pos (..), mkDiagnostic)

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
  fence <- exactlyOnePmlFence path md.mdFences
  body <- case parseModuleBody path fence.mfContent of
    Left bundle -> Left (bundleToDiagnostics path bundle)
    Right b -> Right b
  let sections = buildSections md.mdLines md.mdHeadings md.mdFences
  pure
    LoadedModule
      { lmPath = path,
        lmFrontmatter = fm,
        lmSections = sections,
        lmBody = body
      }

exactlyOnePmlFence :: FilePath -> [MdFence] -> Either [Diagnostic] MdFence
exactlyOnePmlFence path fences =
  case filter isPml fences of
    [f] -> Right f
    [] -> Left [mkDiagnostic path (Pos 1 1) "module requires exactly one ```pml fence"]
    _ -> Left [mkDiagnostic path (Pos 1 1) "module has multiple ```pml fences (v0 allows one)"]
  where
    isPml f =
      case T.words (T.strip f.mfInfo) of
        ("pml" : _) -> True
        _ -> False
