-- | Overloaded pure operators (@==@, ord, arith) and path coercibility.
--
-- Design (replaces M8 ad-hoc Infer special-cases):
--
-- 1. __Applications__ of overloaded ops are typed here by operand sorts,
--    not by the Int stubs in 'Pml.Check.Prelude'.
-- 2. __Arithmetic__ (@+ - * /@): same numeric sort only — @Int@ or @Float@.
--    No @String@ concatenation; no Int/Float mixing.
-- 3. __Ordered comparison__ (@\< \<= \> \>=@): same sort among
--    @Int@ | @Float@ | @String@ | @FileRef@ (paths order as strings).
-- 4. __Equality__ (@== !=@): same comparable sort — bases above plus
--    @Unit@/@Bool@, and structurally @List\<T\>@ / records when fields are
--    comparable (mirrors runtime 'Pml.Eval.Prelude.valueEq').
-- 5. __String ≅ FileRef__ is a dedicated __path coercibility__ rule used by
--    'typesCompatible' (argument passing and overload operand unify). It is
--    not a general subtyping relation and does not fold into \"all eq types
--    are interchangeable\".
-- 6. Bare references to overloaded ops (not applied) have no principal type;
--    they are rejected at check — pick an instance by applying arguments.
module Pml.Check.Overload
  ( OverloadClass (..),
    classifyOp,
    isOverloadedOp,
    inferOverloadedApp,
    typesCompatible,
    pathCompatible,
    isComparable,
    isOrdered,
    isNumeric,
  )
where

import Control.Monad (unless)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Pml.Ast.Expr (Arg (..), Expr (..))
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Env (TypeEnv, resolveType, typeEq)
import Pml.Check.Error (CheckError (..))

data OverloadClass
  = OpEq
  | OpOrd
  | OpArith
  deriving stock (Eq, Show)

classifyOp :: Text -> Maybe OverloadClass
classifyOp = \case
  "==" -> Just OpEq
  "!=" -> Just OpEq
  "<" -> Just OpOrd
  "<=" -> Just OpOrd
  ">" -> Just OpOrd
  ">=" -> Just OpOrd
  "+" -> Just OpArith
  "-" -> Just OpArith
  "*" -> Just OpArith
  "/" -> Just OpArith
  _ -> Nothing

isOverloadedOp :: Expr -> Bool
isOverloadedOp = \case
  EVar (Ident n) -> maybe False (const True) (classifyOp n)
  _ -> False

-- | Type an application of an overloaded binary operator.
inferOverloadedApp ::
  TypeEnv ->
  OverloadClass ->
  (TypeEnv -> Expr -> Either CheckError TypeExpr) ->
  [Arg] ->
  Either CheckError TypeExpr
inferOverloadedApp env cls inferExpr args = case classifyArgs args of
  Left err -> Left err
  Right [a, b] -> do
    ta <- inferExpr env a >>= resolveType env
    tb <- inferExpr env b >>= resolveType env
    case cls of
      OpEq -> do
        unless (isComparable ta) $
          Left (TypeMismatchMsg "equality requires a comparable type" ta tb)
        requireCompatible ta tb
        pure tBool
      OpOrd -> do
        unless (isOrdered ta) $
          Left
            ( TypeMismatchMsg
                "ordered comparison requires Int, Float, String, or FileRef"
                ta
                tb
            )
        requireCompatible ta tb
        pure tBool
      OpArith -> do
        unless (isNumeric ta) $
          Left (TypeMismatchMsg "arithmetic requires Int or Float (no String +)" ta tb)
        -- Same-sort only: path coercibility must not smear Int/Float.
        unless (typeEq ta tb) $
          Left (TypeMismatchMsg "arithmetic requires matching numeric sorts" ta tb)
        pure ta
  Right xs -> Left (ArityMismatch 2 (length xs))

requireCompatible :: TypeExpr -> TypeExpr -> Either CheckError ()
requireCompatible a b =
  if typesCompatible a b
    then Right ()
    else Left (TypeMismatch a b)

-- | Check-time type identity plus path coercibility (@String@ ≅ @FileRef@).
typesCompatible :: TypeExpr -> TypeExpr -> Bool
typesCompatible a b = typeEq a b || pathCompatible a b

-- | Dedicated rule: string path literals may stand where @FileRef@ is expected
-- (and vice versa for @==@ operands). Runtime FileRef is a workspace path string.
pathCompatible :: TypeExpr -> TypeExpr -> Bool
pathCompatible a b =
  (isFileRef a && isStringName b) || (isStringName a && isFileRef b)

isComparable :: TypeExpr -> Bool
isComparable = \case
  TName (TypeName n) ->
    n `elem` ["Unit", "Bool", "Int", "Float", "String", "FileRef"]
  TList t -> isComparable t
  TOption t -> isComparable t
  TResult a b -> isComparable a && isComparable b
  TRecord fs
    | length fs == length (Map.fromList fs) ->
        all (isComparable . snd) fs
  TSecret {} -> False
  TFun {} -> False
  TEffFun {} -> False
  _ -> False

isOrdered :: TypeExpr -> Bool
isOrdered = \case
  TName (TypeName n) -> n `elem` ["Int", "Float", "String", "FileRef"]
  _ -> False

isNumeric :: TypeExpr -> Bool
isNumeric = \case
  TName (TypeName n) -> n == "Int" || n == "Float"
  _ -> False

isFileRef :: TypeExpr -> Bool
isFileRef = \case
  TName (TypeName "FileRef") -> True
  _ -> False

isStringName :: TypeExpr -> Bool
isStringName = \case
  TName (TypeName "String") -> True
  _ -> False

classifyArgs :: [Arg] -> Either CheckError [Expr]
classifyArgs args
  | null args = Right []
  | all isPos args = Right [e | ArgPos e <- args]
  | all isNamed args =
      Left (Unsupported "overloaded operators take positional arguments")
  | otherwise = Left MixedArgs
  where
    isPos = \case
      ArgPos _ -> True
      _ -> False
    isNamed = \case
      ArgNamed {} -> True
      _ -> False

tBool :: TypeExpr
tBool = TName (TypeName "Bool")
