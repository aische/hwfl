module Hwfl.Check.LocateSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Error (CheckError (..), errorPos, errorRoot, renderLocatedCheckError)
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Source (Diagnostic (..), Pos (..), renderDiagnostics)
import Test.Hspec

tInt :: TypeExpr
tInt = TName (TypeName "Int")

tBool :: TypeExpr
tBool = TName (TypeName "Bool")

badModule :: Text
badModule =
  T.unlines
    [ "---",
      "name: workflows/bad",
      "inputs: {}",
      "outputs:",
      "  n: Int",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_: Unit): { n: Int } =",
      "  { n = true }",
      "```"
    ]

spec :: Spec
spec = describe "type error locations" $ do
  it "reports file-absolute line:col on a type mismatch" $ do
    case loadModuleText "bad.md" badModule of
      Left diags -> expectationFailure (T.unpack (renderDiagnostics diags))
      Right loaded -> case checkLoadedModule loaded of
        Right _ -> expectationFailure "expected type error"
        Left err -> do
          errorRoot err
            `shouldBe` TypeMismatch
              (TRecord [(Ident "n", tInt)])
              (TRecord [(Ident "n", tBool)])
          case errorPos err of
            Nothing -> expectationFailure "expected a source position"
            Just p -> do
              -- Opening ``` is line 10; record body with @true@ is line 12.
              posLine p `shouldBe` 12
              renderLocatedCheckError "bad.md" err
                `shouldSatisfy` T.isPrefixOf "bad.md:12:"

  it "keeps parse diagnostics file-absolute inside fences" $ do
    let src =
          T.unlines
            [ "---",
              "name: workflows/parse-bad",
              "inputs: {}",
              "outputs: {}",
              "---",
              "",
              "```hwfl",
              "type Foo = Int",
              ")",
              "```"
            ]
    case loadModuleText "parse-bad.md" src of
      Right _ -> expectationFailure "expected parse error"
      Left diags -> do
        null diags `shouldBe` False
        let d = head diags
        -- Opening ``` is line 7; stray ')' after a committed decl is line 9.
        posLine d.diagPos `shouldBe` 9
        renderDiagnostics diags `shouldSatisfy` T.isInfixOf "parse-bad.md:9:"
