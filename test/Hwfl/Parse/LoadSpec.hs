module Hwfl.Parse.LoadSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.ByteString qualified as BS
import Hwfl.Ast.Decl (ModuleBody (..))
import Hwfl.Ast.Module
import Hwfl.Ast.Name
import Hwfl.Ast.Type (Effect (..))
import Hwfl.Parse.Load (loadModule, loadModuleText)
import Hwfl.Source (renderDiagnostics)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

summariseMd :: Text
summariseMd =
  T.unlines
    [ "---",
      "name: workflows/summarise",
      "inputs:",
      "  path: FileRef",
      "outputs:",
      "  summary: String",
      "effects: [Read, Net]",
      "---",
      "",
      "## system",
      "",
      "You are a concise summariser.",
      "",
      "## schema Output",
      "",
      "- `summary`: One sentence summary.",
      "- score: Quality score.",
      "  Keep this terse.",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(inputs): { summary: String } =",
      "  let contents = fs.read(inputs.path)",
      "  let summary = llm.chat(",
      "    system = @system,",
      "    prompt = $\"Summarise:\\n{contents.text}\",",
      "    model = \"gpt-5\"",
      "  )",
      "  { summary }",
      "```"
    ]

spec :: Spec
spec = describe "markdown module loader" $ do
  it "returns a diagnostic for a missing module file" $
    withSystemTempDirectory "hwfl-load-missing" $ \dir -> do
      result <- loadModule (dir </> "missing.md")
      result `shouldSatisfy` isLeft

  it "returns a diagnostic for non-UTF-8 module bytes" $
    withSystemTempDirectory "hwfl-load-utf8" $ \dir -> do
      let path = dir </> "invalid.md"
      BS.writeFile path (BS.pack [0xff, 0xfe])
      result <- loadModule path
      result `shouldSatisfy` isLeft

  it "loads summarise frontmatter, sections, and kernel AST" $ do
    case loadModuleText "summarise.md" summariseMd of
      Left diags -> expectationFailure (T.unpack (renderDiagnostics diags))
      Right loaded -> do
        fmName (lmFrontmatter loaded) `shouldBe` qnameFromParts ["workflows", "summarise"]
        fmEffects (lmFrontmatter loaded) `shouldBe` Just [EffRead, EffNet]
        map secSlug (lmSections loaded)
          `shouldBe` [Slug "system", Slug "schema-output", Slug "body"]
        case lookupSection "system" (lmSections loaded) of
          Just s -> secBody s `shouldBe` "You are a concise summariser."
          Nothing -> expectationFailure "missing system section"
        lmSchemaDocs loaded
          `shouldBe` [ SchemaDoc
                         (TypeName "Output")
                         [ (Ident "summary", "One sentence summary."),
                           (Ident "score", "Quality score.\nKeep this terse.")
                         ]
                     ]
        case lookupSection "body" (lmSections loaded) of
          Just s -> secBody s `shouldBe` ""
          Nothing -> expectationFailure "missing body section"
        length (mbDecls (lmBody loaded)) `shouldBe` 1
        mbExpr (lmBody loaded) `shouldBe` Nothing

  it "rejects duplicate section slugs (L-7)" $ do
    let src =
          T.unlines
            [ "---",
              "name: workflows/slug-dup",
              "inputs: {}",
              "outputs: {}",
              "---",
              "",
              "## Über",
              "",
              "first",
              "",
              "## ber",
              "",
              "second",
              "",
              "```hwfl",
              "fun main(inputs): {} = {}",
              "```"
            ]
    case loadModuleText "slug-dup.md" src of
      Left diags ->
        T.unpack (renderDiagnostics diags)
          `shouldContain` "duplicate section slug \"ber\""
      Right _ -> expectationFailure "expected duplicate slug error"

  it "rejects empty section slugs (L-7)" $ do
    let src =
          T.unlines
            [ "---",
              "name: workflows/slug-empty",
              "inputs: {}",
              "outputs: {}",
              "---",
              "",
              "## 你好",
              "",
              "body",
              "",
              "```hwfl",
              "fun main(inputs): {} = {}",
              "```"
            ]
    case loadModuleText "slug-empty.md" src of
      Left diags ->
        T.unpack (renderDiagnostics diags)
          `shouldContain` "empty section slug"
      Right _ -> expectationFailure "expected empty slug error"

lookupSection :: Text -> [Section] -> Maybe Section
lookupSection slug = find ((== Slug slug) . secSlug)
  where
    find _ [] = Nothing
    find p (x : xs) = if p x then Just x else find p xs

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
