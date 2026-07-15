-- | Runtime values for the pure evaluator (spec §02 §3).
module Pml.Eval.Value
  ( Value (..),
    Env,
    emptyEnv,
    lookupEnv,
    extendEnv,
    extendEnvMany,
    Builtin (..),
    renderValue,
  )
where

import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Expr (Expr, Param)
import Pml.Ast.Name (Ident (..), TypeName (..))

-- | Environment: identifier → value.
type Env = Map Ident Value

emptyEnv :: Env
emptyEnv = Map.empty

lookupEnv :: Ident -> Env -> Maybe Value
lookupEnv = Map.lookup

extendEnv :: Ident -> Value -> Env -> Env
extendEnv = Map.insert

extendEnvMany :: [(Ident, Value)] -> Env -> Env
extendEnvMany bs e = foldl' (\acc (k, v) -> Map.insert k v acc) e bs

data Builtin
  = BAdd
  | BSub
  | BMul
  | BDiv
  | BEq
  | BNeq
  | BLt
  | BLe
  | BGt
  | BGe
  | BAnd
  | BOr
  | BNot
  deriving stock (Eq, Show)

data Value
  = VUnit
  | VBool Bool
  | VInt Integer
  | VFloat Double
  | VString Text
  | VList [Value]
  | -- | Field order preserved for display; equality is by name.
    VRecord [(Ident, Value)]
  | VVariant TypeName (Maybe Value)
  | -- | Closure over parameter names and body.
    VClosure [Param] Expr Env
  | VBuiltin Builtin
  deriving stock (Eq, Show)

-- | Text rendering for string interpolation (hwfi §3.2.1 / types §3.1 subset).
-- Closures and builtins are not renderable (trap at eval).
renderValue :: Value -> Either Text Text
renderValue = \case
  VUnit -> Right "()"
  VBool True -> Right "true"
  VBool False -> Right "false"
  VInt n -> Right (T.pack (show n))
  VFloat d -> Right (renderFloat d)
  VString t -> Right t
  VList xs -> do
    parts <- traverse renderJsonish xs
    pure ("[" <> T.intercalate "," parts <> "]")
  VRecord fs -> do
    parts <- traverse (\(Ident k, v) -> ((k <> ":") <>) <$> renderJsonish v) (sortFields fs)
    pure ("{" <> T.intercalate "," parts <> "}")
  VVariant (TypeName t) Nothing -> Right t
  VVariant (TypeName t) (Just v) -> do
    inner <- renderJsonish v
    pure (t <> "(" <> inner <> ")")
  VClosure {} -> Left "cannot render a closure as text"
  VBuiltin {} -> Left "cannot render a builtin as text"

renderJsonish :: Value -> Either Text Text
renderJsonish = \case
  VString t -> Right (T.pack (show t)) -- quoted
  v -> renderValue v

renderFloat :: Double -> Text
renderFloat d
  | d == fromIntegral r = T.pack (show r)
  | otherwise = T.pack (show d)
  where
    r = round d :: Integer

sortFields :: [(Ident, Value)] -> [(Ident, Value)]
sortFields = Map.toList . Map.fromList
