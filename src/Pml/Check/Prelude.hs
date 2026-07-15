-- | Prelude and host-op type stubs for the checker (effects deferred to M3).
module Pml.Check.Prelude
  ( preludeTypeEnv,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Env (TypeEnv (..))

preludeTypeEnv :: TypeEnv
preludeTypeEnv =
  TypeEnv
    { teVars =
        Map.fromList $
          binOps
            ++ [ (Ident "not", TFun (t "Bool") (t "Bool")),
                 (Ident "fs", fsType),
                 (Ident "llm", llmType)
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
        TFun (t "FileRef") (TRecord [(Ident "text", t "String")])
      ),
      ( Ident "write",
        TFun
          ( TRecord
              [ (Ident "path", t "FileRef"),
                (Ident "text", t "String")
              ]
          )
          (t "Unit")
      )
    ]

llmType :: TypeExpr
llmType =
  TRecord
    [ ( Ident "chat",
        TFun
          ( TRecord
              [ (Ident "system", t "String"),
                (Ident "prompt", t "String"),
                (Ident "model", t "String")
              ]
          )
          (t "String")
      ),
      ( Ident "object",
        TFun
          ( TRecord
              [ (Ident "prompt", t "String"),
                (Ident "schema", t "Schema"),
                (Ident "model", t "String")
              ]
          )
          (t "Json")
      )
    ]

t :: Text -> TypeExpr
t = TName . TypeName
