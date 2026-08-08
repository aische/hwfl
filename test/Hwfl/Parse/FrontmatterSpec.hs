module Hwfl.Parse.FrontmatterSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (ExampleInputs (..), Frontmatter (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameFromParts)
import Hwfl.Ast.Skill (SkillMeta (..))
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

  describe "skill.tags (L-11)" $ do
    it "parses a list of string tags" $ do
      let src =
            baseFm
              [ "skill:",
                "  tags: [fixture, shell]"
              ]
      case parseFm src of
        Left diags -> expectationFailure (show diags)
        Right fm ->
          case fmSkill fm of
            Just sm -> smTags sm `shouldBe` ["fixture", "shell"]
            Nothing -> expectationFailure "expected skill metadata"

    it "rejects non-string tag entries" $ do
      let src =
            baseFm
              [ "skill:",
                "  tags: [1, \"a\"]"
              ]
      case parseFm src of
        Left diags ->
          diagMsg diags
            `shouldContain` ["skill.tags must be a list of strings"]
        Right fm ->
          expectationFailure
            ("expected rejection, got tags " <> show (fmap smTags (fmSkill fm)))

    it "rejects a non-list tags value" $ do
      case parseFm (baseFm ["skill:", "  tags: shell"]) of
        Left diags ->
          diagMsg diags
            `shouldContain` ["skill.tags must be a list of strings"]
        Right _ -> expectationFailure "expected parse failure"

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

  describe "duplicate keys (M-9)" $ do
    it "rejects duplicate top-level frontmatter keys" $ do
      let src =
            T.unlines
              [ "name: workflows/a",
                "name: workflows/b",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String"
              ]
      case parseFm src of
        Left diags ->
          diagMsg diags
            `shouldSatisfy` any ("duplicate key: name" `T.isInfixOf`)
        Right _ -> expectationFailure "expected duplicate key rejection"

    it "rejects duplicate keys under inputs" $ do
      let src =
            T.unlines
              [ "name: workflows/summarise",
                "inputs:",
                "  path: FileRef",
                "  path: String",
                "outputs:",
                "  summary: String"
              ]
      case parseFm src of
        Left diags ->
          diagMsg diags
            `shouldSatisfy` any ("duplicate key: path" `T.isInfixOf`)
        Right _ -> expectationFailure "expected nested duplicate key rejection"

    it "rejects duplicate keys under nested skill" $ do
      let src =
            baseFm
              [ "skill:",
                "  kind: callable",
                "  kind: instruction"
              ]
      case parseFm src of
        Left diags ->
          diagMsg diags
            `shouldSatisfy` any ("duplicate key: kind" `T.isInfixOf`)
        Right _ -> expectationFailure "expected skill duplicate key rejection"

  describe "resource limits (M-8)" $ do
    it "rejects YAML aliases in frontmatter" $ do
      let src =
            T.unlines
              [ "name: workflows/bomb",
                "a: &x 1",
                "b: *x",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String"
              ]
      case parseFm src of
        Left diags ->
          diagMsg diags
            `shouldSatisfy` any ("aliases are not allowed" `T.isInfixOf`)
        Right _ -> expectationFailure "expected alias rejection"

    it "rejects YAML alias bombs before expansion" $ do
      let levels =
            ["a0: &a0 [1, 2, 3, 4]"]
              ++ [ "a"
                     <> T.pack (show (n :: Int))
                     <> ": &a"
                     <> T.pack (show n)
                     <> " [*a"
                     <> T.pack (show (n - 1))
                     <> ", *a"
                     <> T.pack (show (n - 1))
                     <> ", *a"
                     <> T.pack (show (n - 1))
                     <> ", *a"
                     <> T.pack (show (n - 1))
                     <> "]"
                 | n <- [1 .. 20]
                 ]
          src =
            T.unlines $
              ["name: workflows/bomb"]
                ++ levels
                ++ [ "inputs:",
                     "  path: FileRef",
                     "outputs:",
                     "  summary: String"
                   ]
      case parseFm src of
        Left diags ->
          diagMsg diags
            `shouldSatisfy` any ("aliases are not allowed" `T.isInfixOf`)
        Right _ -> expectationFailure "expected alias bomb rejection"
