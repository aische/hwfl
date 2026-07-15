module Spec (main) where

import Pml.Ast.PrettySpec
import Pml.Check.ModuleSpec
import Pml.Check.SchemaSpec
import Pml.Eval.PureSpec
import Pml.Llm.ProviderSpec
import Pml.Obs.SpanSpec
import Pml.Parse.ExprSpec
import Pml.Parse.LoadSpec
import Pml.Parse.ModuleSpec
import Pml.Parse.SectionSpec
import Pml.Parse.TypeSpec
import Pml.Runtime.AgentSpec
import Pml.Runtime.ConcurrentSpec
import Pml.Runtime.RunSpec
import Pml.Runtime.WorkspaceSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  Pml.Parse.TypeSpec.spec
  Pml.Parse.ExprSpec.spec
  Pml.Parse.ModuleSpec.spec
  Pml.Parse.SectionSpec.spec
  Pml.Parse.LoadSpec.spec
  Pml.Ast.PrettySpec.spec
  Pml.Eval.PureSpec.spec
  Pml.Check.ModuleSpec.spec
  Pml.Check.SchemaSpec.spec
  Pml.Llm.ProviderSpec.spec
  Pml.Runtime.WorkspaceSpec.spec
  Pml.Runtime.RunSpec.spec
  Pml.Runtime.ConcurrentSpec.spec
  Pml.Runtime.AgentSpec.spec
  Pml.Obs.SpanSpec.spec
