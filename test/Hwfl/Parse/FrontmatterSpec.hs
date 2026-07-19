module Hwfl.Parse.FrontmatterSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (ExampleInputs (..), Frontmatter (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameFromParts)
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Parse.Frontmatter (parseFrontmatter)
import Hwfl.Source (Diagnostic (..))
import Test.Hspec

baseFm :: [Text] -> Text
baseFm extra =
  T.unlines $
    [ "name: workflows/summarise",
      "inputs:",
      "  path: FileRef",
      "outputs:",
      "  summary: String"
    ]
      ++ extra

parseFm :: Text -> Either [Diagnostic] Frontmatter
parseFm = parseFrontmatter "t.md"

diagMsg :: [Diagnostic] -> [Text]
diagMsg = map diagMessage

spec :: Spec
spec = describe "frontmatter examples" $ do
  it "omits examples when absent" $ do
    case parseFm (baseFm []) of
      Left diags -> expectationFailure (show diags)
      Right fm -> fmExamples fm `shouldBe` []

  it "treats null and empty list as no examples" $ do
    case parseFm (baseFm ["examples: null"]) of
      Left diags -> expectationFailure (show diags)
      Right fm -> fmExamples fm `shouldBe` []
    case parseFm (baseFm ["examples: []"]) of
      Left diags -> expectationFailure (show diags)
      Right fm -> fmExamples fm `shouldBe` []

  it "parses one named example" $ do
    let src =
          baseFm
            [ "examples:",
              "  - name: readme",
              "    inputs:",
              "      path: README.md"
            ]
    case parseFm src of
      Left diags -> expectationFailure (show diags)
      Right fm -> do
        fmName fm `shouldBe` qnameFromParts ["workflows", "summarise"]
        fmInputs fm
          `shouldBe` [(Ident "path", TName (TypeName "FileRef"))]
        case fmExamples fm of
          [ex] -> do
            eiName ex `shouldBe` Just "readme"
            KM.lookup "path" (eiInputs ex) `shouldBe` Just (String "README.md")
          other -> expectationFailure ("expected one example, got " <> show other)

  it "parses multiple examples including unnamed" $ do
    let src =
          baseFm
            [ "examples:",
              "  - name: readme",
              "    inputs:",
              "      path: README.md",
              "  - inputs:",
              "      path: article.txt"
            ]
    case parseFm src of
      Left diags -> expectationFailure (show diags)
      Right fm ->
        map eiName (fmExamples fm) `shouldBe` [Just "readme", Nothing]

  it "rejects non-list examples" $ do
    case parseFm (baseFm ["examples: {}", ""]) of
      Left diags -> diagMsg diags `shouldContain` ["examples must be a list"]
      Right _ -> expectationFailure "expected parse failure"

  it "rejects example without inputs" $ do
    case parseFm (baseFm ["examples:", "  - name: bare"]) of
      Left diags ->
        diagMsg diags `shouldContain` ["examples[].inputs is required"]
      Right _ -> expectationFailure "expected parse failure"

  it "rejects non-mapping example inputs" $ do
    case parseFm (baseFm ["examples:", "  - inputs: []"]) of
      Left diags ->
        diagMsg diags `shouldContain` ["examples[].inputs must be a mapping"]
      Right _ -> expectationFailure "expected parse failure"

  it "rejects unknown fields on example items" $ do
    case parseFm
      ( baseFm
          [ "examples:",
            "  - name: x",
            "    inputs:",
            "      path: a.md",
            "    description: no"
          ]
      ) of
      Left diags ->
        diagMsg diags
          `shouldContain` ["examples item has unknown fields: description"]
      Right _ -> expectationFailure "expected parse failure"
