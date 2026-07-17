module Spec (main) where

import Hwfl.Ast.PrettySpec
import Hwfl.Check.ModuleSpec
import Hwfl.Check.ProjectSpec
import Hwfl.Check.SchemaSpec
import Hwfl.Eval.PureSpec
import Hwfl.Llm.ProviderSpec
import Hwfl.Obs.SpanSpec
import Hwfl.Parse.ExprSpec
import Hwfl.Parse.LoadSpec
import Hwfl.Parse.ModuleSpec
import Hwfl.Parse.SectionSpec
import Hwfl.Parse.TypeSpec
import Hwfl.Runtime.AgentObjectSpec
import Hwfl.Runtime.AgentSpec
import Hwfl.Runtime.CodingAgentSpec
import Hwfl.Runtime.ConcurrentSpec
import Hwfl.Runtime.HostOpsSpec
import Hwfl.Runtime.ObjectSpec
import Hwfl.Runtime.RunSpec
import Hwfl.Runtime.SemanticCheckSpec
import Hwfl.Runtime.WorkspaceSpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  Hwfl.Parse.TypeSpec.spec
  Hwfl.Parse.ExprSpec.spec
  Hwfl.Parse.ModuleSpec.spec
  Hwfl.Parse.SectionSpec.spec
  Hwfl.Parse.LoadSpec.spec
  Hwfl.Ast.PrettySpec.spec
  Hwfl.Eval.PureSpec.spec
  Hwfl.Check.ModuleSpec.spec
  Hwfl.Check.ProjectSpec.spec
  Hwfl.Check.SchemaSpec.spec
  Hwfl.Llm.ProviderSpec.spec
  Hwfl.Runtime.WorkspaceSpec.spec
  Hwfl.Runtime.RunSpec.spec
  Hwfl.Runtime.ConcurrentSpec.spec
  Hwfl.Runtime.HostOpsSpec.spec
  Hwfl.Runtime.AgentSpec.spec
  Hwfl.Runtime.AgentObjectSpec.spec
  Hwfl.Runtime.ObjectSpec.spec
  Hwfl.Obs.SpanSpec.spec
  Hwfl.Runtime.SemanticCheckSpec.spec
  Hwfl.Runtime.CodingAgentSpec.spec
