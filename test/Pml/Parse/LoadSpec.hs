module Pml.Parse.LoadSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Decl (ModuleBody (..))
import Pml.Ast.Module
import Pml.Ast.Name
import Pml.Ast.Type (Effect (..))
import Pml.Parse.Load (loadModuleText)
import Pml.Source (renderDiagnostics)
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
      "## body",
      "",
      "```pml",
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
  it "loads summarise frontmatter, sections, and kernel AST" $ do
    case loadModuleText "summarise.md" summariseMd of
      Left diags -> expectationFailure (T.unpack (renderDiagnostics diags))
      Right loaded -> do
        fmName (lmFrontmatter loaded) `shouldBe` qnameFromParts ["workflows", "summarise"]
        fmEffects (lmFrontmatter loaded) `shouldBe` Just [EffRead, EffNet]
        map secSlug (lmSections loaded)
          `shouldBe` [Slug "system", Slug "body"]
        case lookupSection "system" (lmSections loaded) of
          Just s -> secBody s `shouldBe` "You are a concise summariser."
          Nothing -> expectationFailure "missing system section"
        case lookupSection "body" (lmSections loaded) of
          Just s -> secBody s `shouldBe` ""
          Nothing -> expectationFailure "missing body section"
        length (mbDecls (lmBody loaded)) `shouldBe` 1
        mbExpr (lmBody loaded) `shouldBe` Nothing

lookupSection :: Text -> [Section] -> Maybe Section
lookupSection slug = find ((== Slug slug) . secSlug)
  where
    find _ [] = Nothing
    find p (x : xs) = if p x then Just x else find p xs
