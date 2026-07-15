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
                 (Ident "exec", execType),
                 (Ident "meta", metaType),
                 (Ident "list", listType),
                 (Ident "text", textType),
                 (Ident "md", mdType),
                 (Ident "json", jsonType),
                 (Ident "ctx", ctxType)
               ],
      teAliases = Map.empty,
      teImports = Map.empty
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
      ),
      ( Ident "find",
        TEffFun
          ( TRecord [(Ident "glob", t "String")] )
          [EffRead]
          (TList (t "FileRef"))
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

metaType :: TypeExpr
metaType =
  TRecord
    [ ( Ident "check_module",
        TEffFun
          (t "FileRef")
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "error", t "String"),
                (Ident "name", t "String")
              ]
          )
      ),
      ( Ident "check_project",
        TEffFun
          (t "FileRef")
          [EffMeta, EffRead]
          (TRecord [(Ident "ok", t "Bool"), (Ident "error", t "String")])
      )
    ]

-- | Domains use Json as a placeholder; Infer special-cases @list.length@ / @list.concat@.
listType :: TypeExpr
listType =
  TRecord
    [ (Ident "length", TFun (TList (t "Json")) (t "Int")),
      ( Ident "concat",
        TFun (TList (t "Json")) (TFun (TList (t "Json")) (TList (t "Json")))
      )
    ]

textType :: TypeExpr
textType =
  TRecord
    [ ( Ident "metrics",
        TFun
          (t "String")
          ( TRecord
              [ (Ident "chars", t "Int"),
                (Ident "tokens", t "Int"),
                (Ident "lines", t "Int"),
                (Ident "entropy", t "Float"),
                (Ident "uniqueness", t "Float")
              ]
          )
      ),
      (Ident "similarity", TFun (t "String") (TFun (t "String") (t "Float"))),
      (Ident "contains", TFun (t "String") (TFun (t "String") (t "Bool"))),
      (Ident "split_sentences", TFun (t "String") (TList (t "String"))),
      (Ident "words", TFun (t "String") (TList (t "String"))),
      ( Ident "strip_suffix",
        TFun (t "String") (TFun (t "String") (t "String"))
      )
    ]

mdType :: TypeExpr
mdType =
  TRecord
    [ ( Ident "sections",
        TFun
          (t "String")
          ( TList
              ( TRecord
                  [ (Ident "slug", t "String"),
                    (Ident "title", t "String"),
                    (Ident "body", t "String")
                  ]
              )
          )
      )
    ]

jsonType :: TypeExpr
jsonType =
  TRecord
    [ ( Ident "encode",
        -- Accept any JSON-encodable value; Infer special-cases @json.encode@.
        TFun (t "Json") (t "String")
      )
    ]

ctxType :: TypeExpr
ctxType =
  TRecord
    [ ( Ident "run",
        TRecord
          [ (Ident "id", t "String"),
            (Ident "started_at", t "String")
          ]
      )
    ]

t :: Text -> TypeExpr
t = TName . TypeName
