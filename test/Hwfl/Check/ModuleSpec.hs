module Hwfl.Check.ModuleSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Decl (ModuleBody)
import Hwfl.Ast.Expr (Expr)
import Hwfl.Ast.Name (TypeName (..))
import Hwfl.Ast.Type (Effect (..), TypeExpr (..))
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Infer (infer)
import Hwfl.Check.Module (CheckResult (..), checkLoadedModule, checkModuleBody)
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Parse.Expr (parseExprText)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Parse.Module (parseModuleBody)
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

    it "infers Float arithmetic as Float" $
      inferE "1.5 + 2.0" `shouldBe` Right (TName (TypeName "Float"))

    it "rejects mixed Int/Float arithmetic" $
      inferE "1 + 2.0" `shouldSatisfy` isLeft

    it "rejects String +" $
      inferE "\"a\" + \"b\"" `shouldSatisfy` isLeft

    it "overloads == on String and Float" $ do
      inferE "\"a\" == \"b\"" `shouldBe` Right (TName (TypeName "Bool"))
      inferE "1.0 == 2.0" `shouldBe` Right (TName (TypeName "Bool"))

    it "overloads ordered comparison on String and Float" $ do
      inferE "\"a\" < \"b\"" `shouldBe` Right (TName (TypeName "Bool"))
      inferE "1.0 < 2.0" `shouldBe` Right (TName (TypeName "Bool"))

    it "accepts structural list/record equality" $ do
      inferE "[1, 2] == [1, 2]" `shouldBe` Right (TName (TypeName "Bool"))
      inferE "{ a = 1 } == { a = 1 }" `shouldBe` Right (TName (TypeName "Bool"))

    it "rejects bare overloaded operator" $
      inferE "==" `shouldSatisfy` isLeft

    it "rejects Bool used as Int" $
      inferE "1 + true" `shouldSatisfy` isLeft

    it "accepts String where FileRef is required (path coercibility)" $
      checkBody
        "fun read_it(p: FileRef): { text: String } =\n  fs.read(p)\n\
        \fun main(_: Unit): { text: String } =\n  read_it(\"notes.md\")"
        `shouldSatisfy` isRight

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
                "```hwfl",
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
                "```hwfl",
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

  describe "effects (M3)" $ do
    it "E12 rejects effects: [Read] with llm.chat" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/e12",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String",
                "effects: [Read]",
                "---",
                "",
                "## system",
                "",
                "Hi.",
                "",
                "## body",
                "",
                "```hwfl",
                "fun main(inputs): { summary: String } =",
                "  let summary = llm.chat(",
                "    system = @system,",
                "    prompt = $\"x {inputs.path}\",",
                "    model = \"gpt-5\"",
                "  )",
                "  { summary }",
                "```"
              ]
      case loadModuleText "e12.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded ->
          checkLoadedModule loaded
            `shouldBe` Left
              ( EffectsNotAllowed
                  (Set.fromList [EffNet])
                  (Set.fromList [EffRead])
              )

    it "accepts summarise-shaped module with [Read, Net]" $ do
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
                "```hwfl",
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

  describe "try/catch" $ do
    it "accepts matching try and catch types" $
      checkBody
        "fun main(_): String =\n\
        \  try fs.read(\"x\").text catch (err) => err"
        `shouldSatisfy` isRight

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isLeft :: Either a b -> Bool
isLeft = not . isRight
