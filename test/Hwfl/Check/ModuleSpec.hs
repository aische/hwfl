module Hwfl.Check.ModuleSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Decl (ModuleBody)
import Hwfl.Ast.Expr (Expr (ELit, EMatch))
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Pat (Literal (..))
import Hwfl.Ast.Type (Effect (..), TypeExpr (..))
import Hwfl.Check.Error (CheckError (..), errorRoot)
import Hwfl.Check.Env (resolveType)
import Hwfl.Check.Infer (check, infer, inferModuleEnv)
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

    it "rejects duplicate record fields (L-16)" $ do
      case parseExpr "{ a = 1, a = 2 }" of
        Left err -> expectationFailure err
        Right e -> case infer preludeTypeEnv e of
          Left err -> errorRoot err `shouldBe` DuplicateField (Ident "a")
          Right _ -> expectationFailure "expected DuplicateField"
      case checkBody "type R = { a: Int, a: Int }\nfun main(_: Unit): Int = 1" of
        Left err -> errorRoot err `shouldBe` DuplicateField (Ident "a")
        Right _ -> expectationFailure "expected DuplicateField"

    it "rejects bare overloaded operator" $
      inferE "==" `shouldSatisfy` isLeft

    it "rejects an empty call to a non-Unit function" $
      inferE "(fun (x: Int): Int => x)()" `shouldSatisfy` isLeft

    it "rejects Bool used as Int" $
      inferE "1 + true" `shouldSatisfy` isLeft

    it "accepts String where FileRef is required (path coercibility)" $
      checkBody
        "fun read_it(p: FileRef): { text: String } =\n  fs.read(p)\n\
        \fun main(_: Unit): { text: String } =\n  read_it(\"notes.md\")"
        `shouldSatisfy` isRight

    it "rejects Secret in interpolation" $
      case checkBody "fun bad(s: Secret<String>): String =\n  $\"{s}\"" of
        Left err ->
          errorRoot err
            `shouldBe` NotRenderable (TSecret (TName (TypeName "String")))
        Right _ -> expectationFailure "expected NotRenderable"

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

    it "memoizes deep alias DAG expansion (M-8)" $ do
      let src =
            "type A0 = { x: Int, y: Int }\n"
              <> T.concat
                [ "type A"
                    <> T.pack (show (n :: Int))
                    <> " = { l: A"
                    <> T.pack (show (n - 1))
                    <> ", r: A"
                    <> T.pack (show (n - 1))
                    <> " }\n"
                  | n <- [1 .. 50]
                ]
              <> "fun main(_: Unit): Int = 1"
      case parseBody src of
        Left err -> expectationFailure err
        Right body -> case inferModuleEnv body of
          Left err -> expectationFailure (show err)
          Right env ->
            -- Fresh resolve of the tip must finish quickly with memoization;
            -- without it this is ~2^50 nodes.
            resolveType env (TName (TypeName "A50")) `shouldSatisfy` isRight

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

    it "accepts examples whose keys match inputs" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/summarise",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String",
                "effects: [Read, Net]",
                "examples:",
                "  - name: readme",
                "    inputs:",
                "      path: README.md",
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

    it "rejects examples with missing or unknown input keys" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/summarise",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String",
                "effects: [Read, Net]",
                "examples:",
                "  - name: bad",
                "    inputs:",
                "      other: x",
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
                "  let contents = fs.read(inputs.path)",
                "  let summary = llm.chat(",
                "    system = @system,",
                "    prompt = $\"x {contents.text}\",",
                "    model = \"gpt-5\"",
                "  )",
                "  { summary }",
                "```"
              ]
      case loadModuleText "summarise.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded ->
          checkLoadedModule loaded
            `shouldBe` Left
              ( ExampleInputsMismatch
                  (Just "bad")
                  [Ident "path"]
                  [Ident "other"]
              )

    it "rejects examples whose values do not match input types" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/typed",
                "inputs:",
                "  n: Int",
                "outputs:",
                "  n: Int",
                "effects: []",
                "examples:",
                "  - name: bad",
                "    inputs:",
                "      n: not-an-int",
                "---",
                "",
                "## body",
                "",
                "```hwfl",
                "fun main(inputs): { n: Int } =",
                "  { n = inputs.n }",
                "```"
              ]
      case loadModuleText "typed.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded ->
          checkLoadedModule loaded
            `shouldSatisfy` ( \case
                                Left (ExampleTypeMismatch (Just "bad") _) -> True
                                _ -> False
                            )

    it "rejects duplicate example names" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/summarise",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  summary: String",
                "effects: [Read, Net]",
                "examples:",
                "  - name: dup",
                "    inputs:",
                "      path: a.md",
                "  - name: dup",
                "    inputs:",
                "      path: b.md",
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
                "  let contents = fs.read(inputs.path)",
                "  let summary = llm.chat(",
                "    system = @system,",
                "    prompt = $\"x {contents.text}\",",
                "    model = \"gpt-5\"",
                "  )",
                "  { summary }",
                "```"
              ]
      case loadModuleText "summarise.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded ->
          checkLoadedModule loaded `shouldBe` Left (ExampleDuplicateName "dup")

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

    it "M-10 charges Write through let-alias of a top-level fun" $ do
      case checkBody
        "fun write_it(p: FileRef): Unit =\n\
        \  fs.write(path = p, text = \"x\")\n\
        \fun main(p: FileRef): Unit =\n\
        \  let g = write_it\n\
        \  g(p)" of
        Right r ->
          Map.lookup (Ident "main") r.crEffects
            `shouldBe` Just (Set.singleton EffWrite)
        Left err -> expectationFailure (show err)

    it "M-10 rejects effects: [] when Write is reached via let-alias" $ do
      let src =
            T.unlines
              [ "---",
                "name: workflows/m10",
                "inputs:",
                "  path: FileRef",
                "outputs:",
                "  ok: Bool",
                "effects: []",
                "---",
                "",
                "## body",
                "",
                "```hwfl",
                "fun write_it(p: FileRef): Unit =",
                "  fs.write(path = p, text = \"x\")",
                "fun main(inputs): { ok: Bool } =",
                "  let g = write_it",
                "  let _ = g(inputs.path)",
                "  { ok = true }",
                "```"
              ]
      case loadModuleText "m10.md" src of
        Left diags -> expectationFailure (show diags)
        Right loaded ->
          checkLoadedModule loaded
            `shouldBe` Left
              ( EffectsNotAllowed
                  (Set.singleton EffWrite)
                  Set.empty
              )

    it "M-10 does not charge shadowed top-level residual via pure let-alias" $ do
      case checkBody
        "fun write_it(p: FileRef): Unit =\n\
        \  fs.write(path = p, text = \"x\")\n\
        \fun main(_: Unit): Unit =\n\
        \  let write_it = fun(_: Unit): Unit => ()\n\
        \  write_it()" of
        Right r ->
          Map.lookup (Ident "main") r.crEffects `shouldBe` Just Set.empty
        Left err -> expectationFailure (show err)

  describe "try/catch" $ do
    it "accepts matching try and catch types" $
      checkBody
        "fun main(_): String =\n\
        \  try fs.read(\"x\").text catch (err) => err"
        `shouldSatisfy` isRight

  describe "match / confirm / choice (High #4)" $ do
    it "rejects empty match in checking mode" $
      case check preludeTypeEnv (EMatch (ELit (LInt 1)) []) (TName (TypeName "Int")) of
        Left err -> errorRoot err `shouldBe` CannotInfer "empty match"
        Right _ -> expectationFailure "expected empty match rejection"

    it "accepts confirm with title only" $
      inferE "confirm { title = \"Proceed?\" }"
        `shouldBe` Right (TName (TypeName "Bool"))

    it "accepts confirm with title and detail" $
      inferE "confirm { title = \"Proceed?\", detail = \"demo\" }"
        `shouldBe` Right (TName (TypeName "Bool"))

    it "rejects confirm without title" $
      inferE "confirm { detail = \"demo\" }" `shouldSatisfy` isLeft

    it "rejects confirm with non-record argument" $
      inferE "confirm 1" `shouldSatisfy` isLeft

    it "rejects confirm with unknown field" $
      inferE "confirm { title = \"t\", extra = 1 }" `shouldSatisfy` isLeft

    it "accepts choice with title and options" $
      inferE "choice { title = \"Pick\", options = [\"a\", \"b\"] }"
        `shouldBe` Right (TName (TypeName "String"))

    it "rejects choice without options" $
      inferE "choice { title = \"Pick\" }" `shouldSatisfy` isLeft

    it "rejects choice without title" $
      inferE "choice { options = [\"a\"] }" `shouldSatisfy` isLeft

    it "accepts human.confirm with optional detail omitted" $
      inferE "human.confirm({ title = \"ok\" })"
        `shouldBe` Right (TName (TypeName "Bool"))

    it "accepts human.choice with optional detail omitted" $
      inferE "human.choice({ title = \"Pick\", options = [\"a\"] })"
        `shouldBe` Right (TName (TypeName "String"))

  describe "value / let polymorphism" $ do
    it "accepts polymorphic identity at Int and String" $
      checkBody
        "fun id(x: a): a = x\n\
        \fun main(_: Unit): { n: Int, s: String } =\n\
        \  { n = id(1), s = id(\"hi\") }"
        `shouldSatisfy` isRight

    it "rejects body that does not respect a type variable" $
      checkBody "fun id(x: a): a = 1"
        `shouldSatisfy` isLeft

    it "accepts multi-param poly app" $
      checkBody
        "fun app(f: (a) -> b, x: a): b = f(x)\n\
        \fun main(_: Unit): Int =\n\
        \  app(fun (n: Int): Int => n + 1, 3)"
        `shouldSatisfy` isRight

    it "accepts map via par over a polymorphic element type" $
      checkBody
        "fun map(xs: List<a>, f: (a) -> b): List<b> =\n\
        \  par for x in xs { f(x) }\n\
        \fun main(_: Unit): List<String> =\n\
        \  map([1, 2], fun (x: Int): String => \"n\")"
        `shouldSatisfy` isRight

    it "instantiates independently at each use site" $
      checkBody
        "fun id(x: a): a = x\n\
        \fun main(_: Unit): Int =\n\
        \  id(1) + id(2)"
        `shouldSatisfy` isRight

    it "rejects mixing Instantiations that break the result type" $
      checkBody
        "fun id(x: a): a = x\n\
        \fun main(_: Unit): Int =\n\
        \  id(1) + id(\"x\")"
        `shouldSatisfy` isLeft

    it "generalizes let-bound fun and allows multiple instantiations" $
      checkBody
        "fun main(_: Unit): { n: Int, s: String } =\n\
        \  let identity = fun (x: a): a => x in\n\
        \  { n = identity(1), s = identity(\"z\") }"
        `shouldSatisfy` isRight

    it "copies schemes through let-alias" $
      checkBody
        "fun id(x: a): a = x\n\
        \fun main(_: Unit): Int =\n\
        \  let f = id in\n\
        \  f(7)"
        `shouldSatisfy` isRight

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isLeft :: Either a b -> Bool
isLeft = not . isRight
