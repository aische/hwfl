module Spec (main) where

import Pml.Ast.PrettySpec
import Pml.Parse.ExprSpec
import Pml.Parse.LoadSpec
import Pml.Parse.ModuleSpec
import Pml.Parse.SectionSpec
import Pml.Parse.TypeSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  Pml.Parse.TypeSpec.spec
  Pml.Parse.ExprSpec.spec
  Pml.Parse.ModuleSpec.spec
  Pml.Parse.SectionSpec.spec
  Pml.Parse.LoadSpec.spec
  Pml.Ast.PrettySpec.spec
