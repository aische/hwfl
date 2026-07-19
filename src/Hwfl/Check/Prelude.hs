-- | Prelude and host-op type stubs for the checker (effects on arrows).
module Hwfl.Check.Prelude
  ( preludeTypeEnv,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (Effect (..), TypeExpr (..))
import Hwfl.Check.Env (TypeEnv (..))

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
                 (Ident "skill", skillType),
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
  [ -- Overloaded kernels: applications are typed by 'Hwfl.Check.Overload'.
    -- Stubs remain so the prelude env is complete; bare uses are rejected
    -- by Infer (no principal type without operands).
    (Ident "+", numBin),
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

-- | Int default instance shown in the prelude table; Float/String dispatch
-- lives in 'Hwfl.Check.Overload' (same-sort; no String @+@).
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
          (TRecord [(Ident "glob", t "String")])
          [EffRead]
          (TList (t "FileRef"))
      ),
      ( Ident "list",
        TEffFun
          (t "FileRef")
          [EffRead]
          ( TList
              ( TRecord
                  [ (Ident "name", t "String"),
                    (Ident "kind", t "String")
                  ]
              )
          )
      ),
      ( Ident "edit",
        TEffFun
          ( TRecord
              [ (Ident "path", t "FileRef"),
                (Ident "old", t "String"),
                (Ident "new", t "String")
              ]
          )
          [EffWrite]
          (TRecord [(Ident "ok", t "Bool")])
      ),
      ( Ident "patch",
        TEffFun
          ( TRecord
              [ (Ident "path", t "FileRef"),
                ( Ident "hunks",
                  TList
                    ( TRecord
                        [ (Ident "old", t "String"),
                          (Ident "new", t "String")
                        ]
                    )
                )
              ]
          )
          [EffWrite]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "applied", t "Int"),
                (Ident "error", t "String")
              ]
          )
      ),
      ( Ident "grep",
        TEffFun
          ( TRecord
              [ (Ident "pattern", t "String"),
                (Ident "glob", t "String")
              ]
          )
          [EffRead]
          ( TList
              ( TRecord
                  [ (Ident "file", t "String"),
                    (Ident "line", t "Int"),
                    (Ident "text", t "String")
                  ]
              )
          )
      ),
      ( Ident "read_slice",
        TEffFun
          ( TRecord
              [ (Ident "path", t "FileRef"),
                (Ident "start_line", t "Int"),
                (Ident "end_line", t "Int")
              ]
          )
          [EffRead]
          (TRecord [(Ident "text", t "String")])
      ),
      ( Ident "remove",
        TEffFun
          (t "FileRef")
          [EffWrite]
          (t "Unit")
      ),
      ( Ident "mkdir",
        TEffFun
          (t "FileRef")
          [EffWrite]
          (t "Unit")
      ),
      ( Ident "copy",
        -- Optional overwrite / exclude via Infer (same pattern as meta.read_spans).
        TEffFun
          ( TRecord
              [ (Ident "src", t "FileRef"),
                (Ident "dst", t "FileRef")
              ]
          )
          [EffWrite]
          (t "Unit")
      ),
      ( Ident "move",
        TEffFun
          ( TRecord
              [ (Ident "src", t "FileRef"),
                (Ident "dst", t "FileRef")
              ]
          )
          [EffWrite]
          (t "Unit")
      ),
      ( Ident "exists",
        TEffFun
          (t "FileRef")
          [EffRead]
          (t "Bool")
      ),
      ( Ident "stat",
        TEffFun
          (t "FileRef")
          [EffRead]
          ( TRecord
              [ (Ident "exists", t "Bool"),
                (Ident "kind", t "String"),
                (Ident "size", t "Int")
              ]
          )
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
        -- Default result is Json; Infer special-cases schema = schema(T) → T (E14).
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
      ),
      ( Ident "agent_object",
        -- Default value field is Json; Infer special-cases schema = schema(T) → T.
        TEffFun
          ( TRecord
              [ (Ident "system", t "String"),
                (Ident "prompt", t "String"),
                (Ident "tools", TList (t "ToolSpec")),
                (Ident "schema", t "Schema"),
                (Ident "model", t "String"),
                (Ident "max_rounds", t "Int")
              ]
          )
          [EffNet]
          ( TRecord
              [ (Ident "value", t "Json"),
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
      ),
      ( Ident "choice",
        TEffFun
          ( TRecord
              [ (Ident "title", t "String"),
                (Ident "detail", t "String"),
                (Ident "options", TList (t "String"))
              ]
          )
          [EffHuman]
          (t "String")
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
        -- Stub for bare / partial @obs.span@; Infer special-cases full apps to
        -- @(name, fun () -> a) -> a@ (E16) so the result is the body type.
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
          ( TRecord
              [ (Ident "exit_code", t "Int"),
                (Ident "stdout", t "String"),
                (Ident "stderr", t "String"),
                (Ident "timed_out", t "Bool")
              ]
          )
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
      ),
      ( Ident "invoke",
        -- Infer special-cases @inputs@ (any record). Stub documents the shape.
        TEffFun
          ( TRecord
              [ (Ident "project", t "FileRef"),
                (Ident "workspace", t "FileRef"),
                (Ident "inputs", t "Json")
              ]
          )
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "run_id", t "String"),
                (Ident "status", t "String"),
                (Ident "outcome", t "Json"),
                (Ident "error", t "String")
              ]
          )
      ),
      ( Ident "list_runs",
        TEffFun
          (TRecord [(Ident "workspace", t "FileRef")])
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "runs", TList runMetaEntryType),
                (Ident "error", t "String")
              ]
          )
      ),
      ( Ident "read_spans",
        -- Infer special-cases optional @name_prefix@ / @kind@ / @limit@.
        TEffFun
          ( TRecord
              [ (Ident "run_id", t "String"),
                (Ident "workspace", t "FileRef"),
                (Ident "name_prefix", t "String"),
                (Ident "kind", t "String"),
                (Ident "limit", t "Int")
              ]
          )
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "spans", TList spanEntryType),
                (Ident "error", t "String")
              ]
          )
      ),
      ( Ident "read_snapshot",
        TEffFun
          ( TRecord
              [ (Ident "run_id", t "String"),
                (Ident "workspace", t "FileRef")
              ]
          )
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "snapshot", t "Json"),
                (Ident "error", t "String")
              ]
          )
      )
    ]

runMetaEntryType :: TypeExpr
runMetaEntryType =
  TRecord
    [ (Ident "run_id", t "String"),
      (Ident "status", t "String"),
      (Ident "entry", t "String"),
      (Ident "started_at", t "String"),
      (Ident "project_hash", t "String")
    ]

spanEntryType :: TypeExpr
spanEntryType =
  TRecord
    [ (Ident "op", t "String"),
      (Ident "id", t "String"),
      (Ident "parent_id", t "String"),
      (Ident "name", t "String"),
      (Ident "kind", t "String"),
      (Ident "t_start", t "String"),
      (Ident "t_end", t "String"),
      (Ident "status", t "String"),
      (Ident "attrs", t "Json"),
      (Ident "snapshot_seq", t "Int")
    ]

skillEntryType :: TypeExpr
skillEntryType =
  TRecord
    [ (Ident "id", t "String"),
      (Ident "kind", t "String"),
      (Ident "summary", t "String"),
      (Ident "tags", TList (t "String")),
      (Ident "checked", t "Bool"),
      (Ident "agent_eligible", t "Bool")
    ]

skillType :: TypeExpr
skillType =
  TRecord
    [ ( Ident "discover",
        TEffFun
          ( TRecord
              [ (Ident "query", t "String"),
                (Ident "kinds", TList (t "String")),
                (Ident "limit", t "Int")
              ]
          )
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "skills", TList skillEntryType),
                (Ident "error", t "String")
              ]
          )
      ),
      ( Ident "load",
        TEffFun
          (TRecord [(Ident "id", t "String")])
          [EffMeta, EffRead]
          ( TRecord
              [ (Ident "ok", t "Bool"),
                (Ident "kind", t "String"),
                (Ident "loaded", t "Bool"),
                (Ident "content", t "String"),
                (Ident "error", t "String")
              ]
          )
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
      ),
      (Ident "trim", TFun (t "String") (t "String")),
      (Ident "starts_with", TFun (t "String") (TFun (t "String") (t "Bool"))),
      (Ident "normalize_token", TFun (t "String") (t "String")),
      (Ident "is_qname", TFun (t "String") (t "Bool"))
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
