module Spec (main) where

import Hwfl.Ast.PrettySpec
import Hwfl.Check.ModuleSpec
import Hwfl.Check.ProjectSpec
import Hwfl.Cli.JsonSpec
import Hwfl.Check.SchemaSpec
import Hwfl.DriverSpec
import Hwfl.Eval.PureSpec
import Hwfl.Llm.PricingSpec
import Hwfl.Llm.ProviderSpec
import Hwfl.Obs.SpanSpec
import Hwfl.Obs.StreamSpec
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
import Hwfl.Runtime.TrySpec
import Hwfl.Runtime.SkillSpec
import Hwfl.Runtime.SemanticCheckSpec
import Hwfl.Runtime.WorkspaceSpec
import Hwfl.SkillCatalogSpec
import Hwfl.Text.CorpusSpec
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
  Hwfl.Cli.JsonSpec.spec
  Hwfl.Check.SchemaSpec.spec
  Hwfl.DriverSpec.spec
  Hwfl.SkillCatalogSpec.spec
  Hwfl.Llm.PricingSpec.spec
  Hwfl.Llm.ProviderSpec.spec
  Hwfl.Runtime.WorkspaceSpec.spec
  Hwfl.Runtime.RunSpec.spec
  Hwfl.Runtime.TrySpec.spec
  Hwfl.Runtime.ConcurrentSpec.spec
  Hwfl.Runtime.HostOpsSpec.spec
  Hwfl.Runtime.AgentSpec.spec
  Hwfl.Runtime.AgentObjectSpec.spec
  Hwfl.Runtime.ObjectSpec.spec
  Hwfl.Obs.SpanSpec.spec
  Hwfl.Obs.StreamSpec.spec
  Hwfl.Runtime.SkillSpec.spec
  Hwfl.Runtime.SemanticCheckSpec.spec
  Hwfl.Text.CorpusSpec.spec
  Hwfl.Runtime.CodingAgentSpec.spec
