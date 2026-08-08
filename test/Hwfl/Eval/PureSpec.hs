module Hwfl.Eval.PureSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Decl (ModuleBody)
import Hwfl.Ast.Expr (Expr, Param (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Eval.Error (EvalError (..))
import Hwfl.Eval.Module (callFun, evalExpr, loadModuleBody)
import Hwfl.Eval.Prelude (applyBuiltin, preludeEnv)
import Hwfl.Eval.Pure (bindParams)
import Hwfl.Eval.Value
import Hwfl.Parse.Expr (parseExprText)
import Hwfl.Parse.Module (parseModuleBody)
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

    it "Float arithmetic" $
      evalE "1.5 + 2.5" `shouldBe` Right (VFloat 4.0)

    it "traps Float arithmetic overflow" $
      applyBuiltin BMul [VFloat 1e308, VFloat 10]
        `shouldBe` Left (Trap "arithmetic produced a non-finite Float")

    it "traps Float division overflow" $
      applyBuiltin BDiv [VFloat 1, VFloat 5e-324]
        `shouldBe` Left (Trap "division produced a non-finite Float")

    it "rejects non-finite Float literals at parse time" $
      evalE (T.replicate 400 "9" <> ".0")
        `shouldSatisfy` isLeft

    it "traps recursive pure evaluation by budget" $
      loadCall
        "fun loop(): Int = loop()"
        (Ident "loop")
        []
        `shouldBe` Left "Trap \"evaluation budget exceeded\""

    it "rejects mixed Int/Float arithmetic" $
      evalE "1 + 2.0" `shouldSatisfy` isLeft

    it "rejects String +" $
      evalE "\"a\" + \"b\"" `shouldSatisfy` isLeft

    it "String / Float equality and ord" $ do
      evalE "\"a\" == \"a\"" `shouldBe` Right (VBool True)
      evalE "\"a\" != \"b\"" `shouldBe` Right (VBool True)
      evalE "1.0 < 2.0" `shouldBe` Right (VBool True)
      evalE "\"a\" < \"b\"" `shouldBe` Right (VBool True)

    it "structural list equality" $
      evalE "[1, 2] == [1, 2]" `shouldBe` Right (VBool True)

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

  describe "parameter binding" $ do
    it "supplies Unit for an omitted Unit parameter" $
      bindParams [Param (Ident "x") (Just (TName (TypeName "Unit")))] []
        `shouldBe` Right [(Ident "x", VUnit)]

    it "supplies Unit for an omitted bare parameter" $
      bindParams [Param (Ident "x") Nothing] []
        `shouldBe` Right [(Ident "x", VUnit)]

    it "packs positional fields for a single record parameter" $
      bindParams
        [Param (Ident "input") (Just (TRecord [(Ident "a", TName (TypeName "Int")), (Ident "b", TName (TypeName "Int"))]))]
        [(Nothing, VInt 1), (Nothing, VInt 2)]
        `shouldBe` Right [(Ident "input", VRecord [(Ident "a", VInt 1), (Ident "b", VInt 2)])]

    it "packs named fields for a single record parameter" $
      bindParams
        [Param (Ident "input") (Just (TRecord [(Ident "a", TName (TypeName "Int")), (Ident "b", TName (TypeName "Int"))]))]
        [(Just (Ident "a"), VInt 1), (Just (Ident "b"), VInt 2)]
        `shouldBe` Right [(Ident "input", VRecord [(Ident "a", VInt 1), (Ident "b", VInt 2)])]

    it "unpacks a whole record for multiple parameters" $
      bindParams
        [ Param (Ident "a") (Just (TName (TypeName "Int"))),
          Param (Ident "b") (Just (TName (TypeName "Int")))
        ]
        [(Nothing, VRecord [(Ident "a", VInt 1), (Ident "b", VInt 2)])]
        `shouldBe` Right [(Ident "a", VInt 1), (Ident "b", VInt 2)]

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
