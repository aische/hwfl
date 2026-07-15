module Pml.Parse.ModuleSpec (spec) where

import Data.Text (Text)
import Pml.Ast.Decl
import Pml.Ast.Expr
import Pml.Ast.Name
import Pml.Ast.Pat (Literal (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Parse.Module (parseModuleBody)
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
                (TypeName "Out")
                (TRecord [(Ident "summary", TName (TypeName "String"))]),
              DFun
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
