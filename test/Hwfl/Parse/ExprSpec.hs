module Hwfl.Parse.ExprSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Expr
import Hwfl.Ast.Name (Ident (..), Slug (..), TypeName (..), qnameFromParts)
import Hwfl.Ast.Pat (Literal (..), Pattern (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Parse.Expr (parseExprText)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

parseE :: Text -> Either String Expr
parseE t = either (Left . errorBundlePretty) Right (parseExprText "e" t)

spec :: Spec
spec = describe "expression parser" $ do
  it "parses literals and lists" $ do
    parseE "42" `shouldBe` Right (ELit (LInt 42))
    parseE "true" `shouldBe` Right (ELit (LBool True))
    parseE "[1, 2]" `shouldBe` Right (EList [ELit (LInt 1), ELit (LInt 2)])

  it "parses records with shorthand fields" $
    parseE "{ summary, ok = true }"
      `shouldBe` Right
        ( ERecord
            [ FieldShorthand (Ident "summary"),
              Field (Ident "ok") (ELit (LBool True))
            ]
        )

  it "parses projection, app, and named args" $
    parseE "llm.chat(system = @system, model = \"gpt-5\")"
      `shouldBe` Right
        ( EApp
            (EProj (EVar (Ident "llm")) (Ident "chat"))
            [ ArgNamed (Ident "system") (ESection (Slug "system")),
              ArgNamed (Ident "model") (ELit (LString "gpt-5"))
            ]
        )

  it "parses slash qnames" $
    parseE "lib/text.trim"
      `shouldBe` Right (EProj (EQName (qnameFromParts ["lib", "text"])) (Ident "trim"))

  it "parses spaced slash as division, not qname (L-5)" $
    parseE "a / b"
      `shouldBe` Right
        ( EApp
            (EVar (Ident "/"))
            [ArgPos (EVar (Ident "a")), ArgPos (EVar (Ident "b"))]
        )

  it "parses tight slash as qname (L-5)" $
    parseE "a/b" `shouldBe` Right (EQName (qnameFromParts ["a", "b"]))

  it "parses interpolation" $
    parseE "$\"hi {name}\""
      `shouldBe` Right (EInterp [SLit "hi ", SInterp (EVar (Ident "name"))])

  it "parses let/in and sequential let" $ do
    parseE "let x = 1 in x"
      `shouldBe` Right (ELet (Ident "x") Nothing (ELit (LInt 1)) (EVar (Ident "x")))
    parseE "let x = 1\nlet y = 2\ny"
      `shouldBe` Right
        ( ELet
            (Ident "x")
            Nothing
            (ELit (LInt 1))
            (ELet (Ident "y") Nothing (ELit (LInt 2)) (EVar (Ident "y")))
        )

  it "rejects same-line implicit let body (L-6)" $
    parseE "let x = a b" `shouldSatisfy` isLeft

  it "desugars && / || to if (L-14)" $ do
    parseE "a && b"
      `shouldBe` Right
        ( EIf
            (EVar (Ident "a"))
            (EVar (Ident "b"))
            (ELit (LBool False))
        )
    parseE "a || b"
      `shouldBe` Right
        ( EIf
            (EVar (Ident "a"))
            (ELit (LBool True))
            (EVar (Ident "b"))
        )

  it "parses match" $
    parseE "match xs with | [] => 0 | [x] => x | _ => -1"
      `shouldBe` Right
        ( EMatch
            (EVar (Ident "xs"))
            [ MatchArm (PList []) (ELit (LInt 0)),
              MatchArm (PList [PVar (Ident "x")]) (EVar (Ident "x")),
              MatchArm PWild (ELit (LInt (-1)))
            ]
        )

  it "parses par and confirm" $
    parseE "par(max = 2) for name in xs { confirm { title = name } }"
      `shouldBe` Right
        ( EPar
            [ParMax 2]
            (Ident "name")
            (EVar (Ident "xs"))
            (EConfirm (ERecord [Field (Ident "title") (EVar (Ident "name"))]))
        )

  it "parses choice" $
    parseE "choice { title = \"t\", options = [\"a\", \"b\"] }"
      `shouldBe` Right
        ( EChoice
            ( ERecord
                [ Field (Ident "title") (ELit (LString "t")),
                  Field
                    (Ident "options")
                    (EList [ELit (LString "a"), ELit (LString "b")])
                ]
            )
        )

  it "parses typed fun expression" $
    parseE "fun (x: Int): Int => x"
      `shouldBe` Right
        ( EFun
            [Param (Ident "x") (Just (TName (TypeName "Int")))]
            (Just (TName (TypeName "Int")))
            (EVar (Ident "x"))
        )

  it "parses infix + as prelude app" $
    parseE "x + y"
      `shouldBe` Right
        ( EApp
            (EVar (Ident "+"))
            [ArgPos (EVar (Ident "x")), ArgPos (EVar (Ident "y"))]
        )

  describe "resource limits (M-8)" $ do
    it "rejects deeply nested parentheses" $ do
      let src = T.replicate 300 "(" <> "1" <> T.replicate 300 ")"
      case parseE src of
        Left msg -> msg `shouldSatisfy` ("nesting exceeds" `T.isInfixOf`) . T.pack
        Right _ -> expectationFailure "expected nesting failure"

    it "rejects oversized integer digit runs" $ do
      let src = T.replicate 5000 "9"
      case parseE src of
        Left msg -> msg `shouldSatisfy` ("digits" `T.isInfixOf`) . T.pack
        Right _ -> expectationFailure "expected digit-length failure"

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
