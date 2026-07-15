-- | Prelude and host-op type stubs for the checker (effects on arrows).
module Pml.Check.Prelude
  ( preludeTypeEnv,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (Effect (..), TypeExpr (..))
import Pml.Check.Env (TypeEnv (..))

preludeTypeEnv :: TypeEnv
preludeTypeEnv =
  TypeEnv
    { teVars =
        Map.fromList $
          binOps
            ++ [ (Ident "not", TFun (t "Bool") (t "Bool")),
                 -- Domain is a placeholder; Infer special-cases @tool(f)@ for any function.
                 ( Ident "tool",
                   TFun (TFun (t "Json") (t "Json")) (t "ToolSpec")
                 ),
                 (Ident "fs", fsType),
                 (Ident "llm", llmType),
                 (Ident "human", humanType),
                 (Ident "obs", obsType),
                 (Ident "exec", execType)
               ],
      teAliases = Map.empty
    }

binOps :: [(Ident, TypeExpr)]
binOps =
  [ (Ident "+", numBin),
    (Ident "-", numBin),
    (Ident "*", numBin),
    (Ident "/", numBin),
    (Ident "==", eqBin),
    (Ident "!=", eqBin),
    (Ident "<", ordBin),
    (Ident "<=", ordBin),
    (Ident ">", ordBin),
    (Ident ">=", ordBin),
    (Ident "&&", boolBin),
    (Ident "||", boolBin)
  ]

-- | Numeric binaries are typed as Int->Int->Int at check time.
-- Float uses are accepted via a narrow special case in application.
numBin :: TypeExpr
numBin = TFun (t "Int") (TFun (t "Int") (t "Int"))

eqBin :: TypeExpr
eqBin = TFun (t "Int") (TFun (t "Int") (t "Bool"))

ordBin :: TypeExpr
ordBin = TFun (t "Int") (TFun (t "Int") (t "Bool"))

boolBin :: TypeExpr
boolBin = TFun (t "Bool") (TFun (t "Bool") (t "Bool"))

fsType :: TypeExpr
fsType =
  TRecord
    [ ( Ident "read",
        TEffFun (t "FileRef") [EffRead] (TRecord [(Ident "text", t "String")])
      ),
      ( Ident "write",
        TEffFun
          ( TRecord
              [ (Ident "path", t "FileRef"),
                (Ident "text", t "String")
              ]
          )
          [EffWrite]
          (t "Unit")
      )
    ]

llmType :: TypeExpr
llmType =
  TRecord
    [ ( Ident "chat",
        TEffFun
          ( TRecord
              [ (Ident "system", t "String"),
                (Ident "prompt", t "String"),
                (Ident "model", t "String")
              ]
          )
          [EffNet]
          (t "String")
      ),
      ( Ident "object",
        TEffFun
          ( TRecord
              [ (Ident "prompt", t "String"),
                (Ident "schema", t "Schema"),
                (Ident "model", t "String")
              ]
          )
          [EffNet]
          (t "Json")
      ),
      ( Ident "agent",
        TEffFun
          ( TRecord
              [ (Ident "system", t "String"),
                (Ident "prompt", t "String"),
                (Ident "tools", TList (t "ToolSpec")),
                (Ident "model", t "String"),
                (Ident "max_rounds", t "Int")
              ]
          )
          [EffNet]
          ( TRecord
              [ (Ident "text", t "String"),
                (Ident "rounds", t "Int")
              ]
          )
      )
    ]

humanType :: TypeExpr
humanType =
  TRecord
    [ ( Ident "confirm",
        TEffFun
          ( TRecord
              [ (Ident "title", t "String"),
                (Ident "detail", t "String")
              ]
          )
          [EffHuman]
          (t "Bool")
      )
    ]

obsType :: TypeExpr
obsType =
  TRecord
    [ ( Ident "log",
        -- Observability is pure-ish (spec §05 §5); no residual effects.
        TFun
          ( TRecord
              [ (Ident "level", t "String"),
                (Ident "message", t "String"),
                (Ident "fields", t "Json")
              ]
          )
          (t "Unit")
      ),
      ( Ident "span",
        -- Region wrapper; polymorphic result deferred — body typed as Unit->Unit for v0.
        TFun (t "String") (TFun (TFun (t "Unit") (t "Unit")) (t "Unit"))
      )
    ]

execType :: TypeExpr
execType =
  TRecord
    [ ( Ident "run",
        TEffFun
          ( TRecord
              [ (Ident "program", t "String"),
                (Ident "args", TList (t "String")),
                (Ident "stdin", t "String")
              ]
          )
          [EffExec]
          (t "Unit")
      )
    ]

t :: Text -> TypeExpr
t = TName . TypeName
