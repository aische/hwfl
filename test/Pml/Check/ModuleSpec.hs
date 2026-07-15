module Pml.Check.ModuleSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Decl (ModuleBody)
import Pml.Ast.Expr (Expr)
import Pml.Ast.Name (TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Error (CheckError (..))
import Pml.Check.Infer (infer)
import Pml.Check.Module (CheckResult (..), checkLoadedModule, checkModuleBody)
import Pml.Check.Prelude (preludeTypeEnv)
import Pml.Parse.Expr (parseExprText)
import Pml.Parse.Load (loadModuleText)
import Pml.Parse.Module (parseModuleBody)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

parseExpr :: Text -> Either String Expr
parseExpr t = either (Left . errorBundlePretty) Right (parseExprText "e" t)

parseBody :: Text -> Either String ModuleBody
parseBody t = either (Left . errorBundlePretty) Right (parseModuleBody "m" t)

inferE :: Text -> Either String TypeExpr
inferE src = do
  e <- parseExpr src
  either (Left . show) Right (infer preludeTypeEnv e)

checkBody :: Text -> Either CheckError CheckResult
checkBody src = case parseBody src of
  Left err -> Left (Unsupported (T.pack err))
  Right body -> checkModuleBody body

spec :: Spec
spec = describe "type checker" $ do
  describe "E01 hello pure" $ do
    it "accepts fun main(_): { msg: String }" $
      checkBody
        "fun main(_): { msg: String } =\n  { msg = \"hello\" }"
        `shouldSatisfy` isRight

  describe "E02 let / match" $ do
    it "accepts pick" $
      checkBody
        "fun pick(xs: List<Int>): Int =\n\
        \  match xs with\n\
        \  | [] => 0\n\
        \  | [x] => x\n\
        \  | [x, y] => x + y\n\
        \  | _ => -1"
        `shouldSatisfy` isRight

  describe "local inference" $ do
    it "infers let / arithmetic as Int" $
      inferE "let x = 1\nlet y = 2\nx + y"
        `shouldBe` Right (TName (TypeName "Int"))

    it "rejects Bool used as Int" $
      inferE "1 + true" `shouldSatisfy` isLeft

    it "rejects Secret in interpolation" $
      checkBody
        "fun bad(s: Secret<String>): String =\n  $\"{s}\""
        `shouldBe` Left (NotRenderable (TSecret (TName (TypeName "String"))))

  describe "type aliases" $ do
    it "resolves aliases" $
      checkBody
        "type Out = { summary: String, score: Int }\n\
        \fun pack(_: Unit): Out =\n\
        \  { summary = \"ok\", score = 1 }"
        `shouldSatisfy` isRight

    it "rejects alias cycles" $
      checkBody
        "type A = B\n\
        \type B = A\n\
        \fun main(_: Unit): Int = 1"
        `shouldBe` Left (AliasCycle [TypeName "A", TypeName "B", TypeName "A"])

  describe "module I/O vs main" $ do
    it "accepts summarise frontmatter vs main" $ do
      let src =
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
                "    prompt = $\"Summarise:\\n\\n{contents.text}\",",
                "    model = \"gpt-5\"",
                "  )",
                "  { summary }",
                "```"
              ]
      case loadModuleText "summarise.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> checkLoadedModule loaded `shouldSatisfy` isRight

    it "rejects main return mismatch" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/bad",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String",
                "---",
                "",
                "## body",
                "",
                "```pml",
                "fun main(inputs): { other: Int } =",
                "  { other = 1 }",
                "```"
              ]
      case loadModuleText "bad.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded ->
          checkLoadedModule loaded
            `shouldSatisfy` ( \case
                                Left MainReturnMismatch {} -> True
                                Left TypeMismatch {} -> True
                                _ -> False
                            )

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isLeft :: Either a b -> Bool
isLeft = not . isRight
