module Pml.Ast.PrettySpec (spec) where

import Data.Text (Text)
import Pml.Ast.Pretty (prettyExpr, prettyModuleBody)
import Pml.Parse.Expr (parseExprText)
import Pml.Parse.Module (parseModuleBody)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

roundTripExpr :: Text -> Either String Text
roundTripExpr src = do
  e1 <- either (Left . errorBundlePretty) Right (parseExprText "e" src)
  let pretty = prettyExpr e1
  e2 <- either (Left . errorBundlePretty) Right (parseExprText "e" pretty)
  if e1 == e2 then Right pretty else Left "AST drift after pretty"

roundTripModule :: Text -> Either String Text
roundTripModule src = do
  m1 <- either (Left . errorBundlePretty) Right (parseModuleBody "m" src)
  let pretty = prettyModuleBody m1
  m2 <- either (Left . errorBundlePretty) Right (parseModuleBody "m" pretty)
  if m1 == m2 then Right pretty else Left "module AST drift after pretty"

spec :: Spec
spec = describe "pretty round-trip" $ do
  it "round-trips apps and records" $
    roundTripExpr "llm.chat(system = @system, model = \"gpt-5\")" `shouldSatisfy` isRight

  it "round-trips match" $
    roundTripExpr "match xs with | [] => 0 | [x] => x | _ => -1" `shouldSatisfy` isRight

  it "round-trips E01 module" $
    roundTripModule "fun main(_): { msg: String } =\n  { msg = \"hello\" }" `shouldSatisfy` isRight
  where
    isRight (Right _) = True
    isRight _ = False
