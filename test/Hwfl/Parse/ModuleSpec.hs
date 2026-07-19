module Hwfl.Parse.ModuleSpec (spec) where

import Data.Text (Text)
import Hwfl.Ast.Decl
import Hwfl.Ast.Expr
import Hwfl.Ast.Name
import Hwfl.Ast.Pat (Literal (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Parse.Module (parseModuleBody)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

parseM :: Text -> Either String ModuleBody
parseM t = either (Left . errorBundlePretty) Right (parseModuleBody "m" t)

spec :: Spec
spec = describe "module body parser" $ do
  it "parses E01 hello pure" $
    parseM "fun main(_): { msg: String } =\n  { msg = \"hello\" }"
      `shouldBe` Right
        ( ModuleBody
            [ DFun
                noPos
                (Ident "main")
                [Param (Ident "_") Nothing]
                (Just (TRecord [(Ident "msg", TName (TypeName "String"))]))
                (ERecord [Field (Ident "msg") (ELit (LString "hello"))])
            ]
            Nothing
        )

  it "parses type + fun decls" $
    parseM "type Out = { summary: String }\nfun f(x: Int): Int = x"
      `shouldBe` Right
        ( ModuleBody
            [ DType
                noPos
                (TypeName "Out")
                (TRecord [(Ident "summary", TName (TypeName "String"))]),
              DFun
                noPos
                (Ident "f")
                [Param (Ident "x") (Just (TName (TypeName "Int")))]
                (Just (TName (TypeName "Int")))
                (EVar (Ident "x"))
            ]
            Nothing
        )

  it "parses E02 match skeleton" $
    parseM
      "fun pick(xs: List<Int>): Int =\n\
      \  match xs with\n\
      \  | [] => 0\n\
      \  | [x] => x\n\
      \  | _ => -1"
      `shouldSatisfy` isRight
  where
    isRight (Right _) = True
    isRight _ = False
