module Pml.Eval.PureSpec (spec) where

import Data.Text (Text)
import Pml.Ast.Decl (ModuleBody)
import Pml.Ast.Expr (Expr)
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Module (callFun, evalExpr, loadModuleBody)
import Pml.Eval.Prelude (preludeEnv)
import Pml.Eval.Value
import Pml.Parse.Expr (parseExprText)
import Pml.Parse.Module (parseModuleBody)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

parseE :: Text -> Either String Expr
parseE t = either (Left . errorBundlePretty) Right (parseExprText "e" t)

parseM :: Text -> Either String ModuleBody
parseM t = either (Left . errorBundlePretty) Right (parseModuleBody "m" t)

evalE :: Text -> Either String Value
evalE src = do
  e <- parseE src
  either (Left . show) Right (evalExpr preludeEnv e)

loadCall :: Text -> Ident -> [Value] -> Either String Value
loadCall src name args = do
  body <- parseM src
  env <- either (Left . show) Right (loadModuleBody body)
  either (Left . show) Right (callFun env name args)

spec :: Spec
spec = describe "pure evaluator" $ do
  describe "E01 hello pure" $ do
    it "returns { msg = \"hello\" }" $
      loadCall
        "fun main(_): { msg: String } =\n  { msg = \"hello\" }"
        (Ident "main")
        [VUnit]
        `shouldBe` Right (VRecord [(Ident "msg", VString "hello")])

  describe "E02 let / match" $ do
    let pickSrc =
          "fun pick(xs: List<Int>): Int =\n\
          \  match xs with\n\
          \  | [] => 0\n\
          \  | [x] => x\n\
          \  | [x, y] => x + y\n\
          \  | _ => -1"
    it "empty -> 0" $
      loadCall pickSrc (Ident "pick") [VList []] `shouldBe` Right (VInt 0)
    it "singleton -> x" $
      loadCall pickSrc (Ident "pick") [VList [VInt 7]] `shouldBe` Right (VInt 7)
    it "[x,y] -> x + y" $
      loadCall pickSrc (Ident "pick") [VList [VInt 3, VInt 4]] `shouldBe` Right (VInt 7)
    it "longer -> -1" $
      loadCall pickSrc (Ident "pick") [VList [VInt 1, VInt 2, VInt 3]] `shouldBe` Right (VInt (-1))

  describe "small pure cases" $ do
    it "let / arithmetic" $
      evalE "let x = 1\nlet y = 2\nx + y" `shouldBe` Right (VInt 3)

    it "if / bool" $
      evalE "if true then 1 else 0" `shouldBe` Right (VInt 1)

    it "fun application" $
      evalE "(fun (x: Int): Int => x + 1)(41)" `shouldBe` Right (VInt 42)

    it "record shorthand" $
      evalE "let name = \"a\"\n{ name, n = 1 }"
        `shouldBe` Right (VRecord [(Ident "name", VString "a"), (Ident "n", VInt 1)])

    it "projection and index" $
      evalE "let r = { a = [10, 20] }\nr.a[1]" `shouldBe` Right (VInt 20)

    it "interpolation" $
      evalE "let n = 3\n$\"x={n}\"" `shouldBe` Right (VString "x=3")

    it "rejects par" $
      evalE "par for x in xs { x }"
        `shouldBe` Left (show (Unsupported "par is not pure" :: EvalError))
