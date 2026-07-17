-- | Pure prelude builtins (arithmetic, comparisons, bool, list, text) — not host ops.
--
-- Overload rules mirror 'Hwfl.Check.Overload':
-- * arith: Int+Int or Float+Float only (no String @+@, no mixed sorts)
-- * ord: matching Int, Float, or String (FileRef is a path string at runtime)
-- * eq: structural for comparable values; traps on closures / host / secrets
module Hwfl.Eval.Prelude
  ( preludeEnv,
    applyBuiltin,
  )
where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Eval.Error (EvalError (..))
import Hwfl.Eval.Value
  ( Builtin (..),
    Env,
    Value (..),
  )
import Hwfl.Json.Encode (valueToJsonText)
import Hwfl.Text.Corpus
  ( TextMetrics (..),
    splitSentences,
    textContains,
    textIsQname,
    textMetrics,
    textNormalizeToken,
    textSimilarity,
    textStartsWith,
    textTrim,
  )
import Hwfl.Text.Markdown (MdSection (..), extractSections)

preludeEnv :: Env
preludeEnv =
  Map.fromList
    [ (Ident "+", VBuiltin BAdd),
      (Ident "-", VBuiltin BSub),
      (Ident "*", VBuiltin BMul),
      (Ident "/", VBuiltin BDiv),
      (Ident "==", VBuiltin BEq),
      (Ident "!=", VBuiltin BNeq),
      (Ident "<", VBuiltin BLt),
      (Ident "<=", VBuiltin BLe),
      (Ident ">", VBuiltin BGt),
      (Ident ">=", VBuiltin BGe),
      (Ident "&&", VBuiltin BAnd),
      (Ident "||", VBuiltin BOr),
      (Ident "not", VBuiltin BNot),
      (Ident "tool", VBuiltin BTool),
      ( Ident "list",
        VRecord
          [ (Ident "length", VBuiltin BListLength),
            (Ident "concat", VBuiltin BListConcat)
          ]
      ),
      ( Ident "text",
        VRecord
          [ (Ident "metrics", VBuiltin BTextMetrics),
            (Ident "similarity", VBuiltin BTextSimilarity),
            (Ident "contains", VBuiltin BTextContains),
            (Ident "split_sentences", VBuiltin BTextSplitSentences),
            (Ident "words", VBuiltin BTextWords),
            (Ident "strip_suffix", VBuiltin BTextStripSuffix),
            (Ident "trim", VBuiltin BTextTrim),
            (Ident "starts_with", VBuiltin BTextStartsWith),
            (Ident "normalize_token", VBuiltin BTextNormalizeToken),
            (Ident "is_qname", VBuiltin BTextIsQname)
          ]
      ),
      ( Ident "md",
        VRecord
          [ (Ident "sections", VBuiltin BMdSections)
          ]
      ),
      ( Ident "json",
        VRecord
          [ (Ident "encode", VBuiltin BJsonEncode)
          ]
      )
    ]

applyBuiltin :: Builtin -> [Value] -> Either EvalError Value
applyBuiltin b args = case (b, args) of
  (BAdd, [a, c]) -> num2 (+) (+) a c
  (BSub, [a, c]) -> num2 (-) (-) a c
  (BMul, [a, c]) -> num2 (*) (*) a c
  (BDiv, [a, c]) -> div2 a c
  (BEq, [a, c]) -> VBool <$> valueEq a c
  (BNeq, [a, c]) -> VBool . not <$> valueEq a c
  (BLt, [a, c]) -> ord2 (<) (<) (<) a c
  (BLe, [a, c]) -> ord2 (<=) (<=) (<=) a c
  (BGt, [a, c]) -> ord2 (>) (>) (>) a c
  (BGe, [a, c]) -> ord2 (>=) (>=) (>=) a c
  (BAnd, [VBool x, VBool y]) -> Right (VBool (x && y))
  (BOr, [VBool x, VBool y]) -> Right (VBool (x || y))
  (BNot, [VBool x]) -> Right (VBool (not x))
  (BTool, _) ->
    Left (Trap "tool() requires the host runtime (typed ToolSpec)")
  (BListLength, [VList xs]) -> Right (VInt (fromIntegral (length xs)))
  (BListConcat, [VList xs, VList ys]) -> Right (VList (xs ++ ys))
  (BTextMetrics, [VString s]) -> Right (metricsValue (textMetrics s))
  (BTextSimilarity, [VString a, VString c]) -> Right (VFloat (textSimilarity a c))
  (BTextContains, [VString hay, VString needle]) -> Right (VBool (textContains hay needle))
  (BTextSplitSentences, [VString s]) ->
    Right (VList (map VString (splitSentences s)))
  (BTextWords, [VString s]) ->
    Right (VList (map VString (T.words s)))
  (BTextTrim, [VString s]) -> Right (VString (textTrim s))
  (BTextStartsWith, [VString s, VString prefix]) ->
    Right (VBool (textStartsWith s prefix))
  (BTextNormalizeToken, [VString s]) ->
    Right (VString (textNormalizeToken s))
  (BTextIsQname, [VString s]) -> Right (VBool (textIsQname s))
  (BTextStripSuffix, [VString s, VString suf]) ->
    Right (VString (fromMaybe s (T.stripSuffix suf s)))
  (BMdSections, [VString s]) -> case extractSections s of
    Left err -> Left (Trap ("md.sections: " <> err))
    Right secs -> Right (VList (map sectionValue secs))
  (BJsonEncode, [v]) -> Right (VString (valueToJsonText v))
  (BAnd, _) -> arityOrType "&&" 2 args
  (BOr, _) -> arityOrType "||" 2 args
  (BNot, _) -> arityOrType "not" 1 args
  (BListLength, _) -> arityOrType "list.length" 1 args
  (BListConcat, _) -> arityOrType "list.concat" 2 args
  (BTextMetrics, _) -> arityOrType "text.metrics" 1 args
  (BTextSimilarity, _) -> arityOrType "text.similarity" 2 args
  (BTextContains, _) -> arityOrType "text.contains" 2 args
  (BTextSplitSentences, _) -> arityOrType "text.split_sentences" 1 args
  (BTextWords, _) -> arityOrType "text.words" 1 args
  (BTextTrim, _) -> arityOrType "text.trim" 1 args
  (BTextStartsWith, _) -> arityOrType "text.starts_with" 2 args
  (BTextNormalizeToken, _) -> arityOrType "text.normalize_token" 1 args
  (BTextIsQname, _) -> arityOrType "text.is_qname" 1 args
  (BTextStripSuffix, _) -> arityOrType "text.strip_suffix" 2 args
  (BMdSections, _) -> arityOrType "md.sections" 1 args
  (BJsonEncode, _) -> arityOrType "json.encode" 1 args
  (_, _) -> Left (Trap ("wrong arity for builtin: " <> T.pack (show b)))

metricsValue :: TextMetrics -> Value
metricsValue m =
  VRecord
    [ (Ident "chars", VInt (fromIntegral m.tmChars)),
      (Ident "tokens", VInt (fromIntegral m.tmTokens)),
      (Ident "lines", VInt (fromIntegral m.tmLines)),
      (Ident "entropy", VFloat m.tmShannonEntropy),
      (Ident "uniqueness", VFloat m.tmUniqueness)
    ]

sectionValue :: MdSection -> Value
sectionValue s =
  VRecord
    [ (Ident "slug", VString s.msSlug),
      (Ident "title", VString s.msTitle),
      (Ident "body", VString s.msBody)
    ]

num2 ::
  (Integer -> Integer -> Integer) ->
  (Double -> Double -> Double) ->
  Value ->
  Value ->
  Either EvalError Value
num2 fi ff a b = case (a, b) of
  (VInt x, VInt y) -> Right (VInt (fi x y))
  (VFloat x, VFloat y) -> Right (VFloat (ff x y))
  _ -> Left (Trap "arithmetic expects Int+Int or Float+Float")

div2 :: Value -> Value -> Either EvalError Value
div2 a b = case (a, b) of
  (VInt _, VInt 0) -> Left (Trap "division by zero")
  (VInt x, VInt y) -> Right (VInt (x `div` y))
  (VFloat _, VFloat 0) -> Left (Trap "division by zero")
  (VFloat x, VFloat y) -> Right (VFloat (x / y))
  _ -> Left (Trap "division expects Int+Int or Float+Float")

ord2 ::
  (Integer -> Integer -> Bool) ->
  (Double -> Double -> Bool) ->
  (Text -> Text -> Bool) ->
  Value ->
  Value ->
  Either EvalError Value
ord2 fi ff fs a b = case (a, b) of
  (VInt x, VInt y) -> Right (VBool (fi x y))
  (VFloat x, VFloat y) -> Right (VBool (ff x y))
  (VString x, VString y) -> Right (VBool (fs x y))
  _ ->
    Left
      ( Trap
          "ordered comparison expects matching Int, Float, or String (FileRef is a path string)"
      )

-- | Structural equality for comparable values (aligned with check overloading).
-- Non-comparable payloads (closures, host ops, secrets, …) trap.
valueEq :: Value -> Value -> Either EvalError Bool
valueEq a b = case (a, b) of
  (VClosure {}, _) -> Left (Trap "cannot compare closures")
  (_, VClosure {}) -> Left (Trap "cannot compare closures")
  (VTopFun {}, _) -> Left (Trap "cannot compare top-level funs")
  (_, VTopFun {}) -> Left (Trap "cannot compare top-level funs")
  (VBuiltin {}, _) -> Left (Trap "cannot compare builtins")
  (_, VBuiltin {}) -> Left (Trap "cannot compare builtins")
  (VHostOp {}, _) -> Left (Trap "cannot compare host ops")
  (_, VHostOp {}) -> Left (Trap "cannot compare host ops")
  (VToolSpec {}, _) -> Left (Trap "cannot compare tool specs")
  (_, VToolSpec {}) -> Left (Trap "cannot compare tool specs")
  (VSkillMain {}, _) -> Left (Trap "cannot compare skill mains")
  (_, VSkillMain {}) -> Left (Trap "cannot compare skill mains")
  (VSchema {}, _) -> Left (Trap "cannot compare schemas")
  (_, VSchema {}) -> Left (Trap "cannot compare schemas")
  (VSecret {}, _) -> Left (Trap "cannot compare secrets")
  (_, VSecret {}) -> Left (Trap "cannot compare secrets")
  (VUnit, VUnit) -> Right True
  (VBool x, VBool y) -> Right (x == y)
  (VInt x, VInt y) -> Right (x == y)
  (VFloat x, VFloat y) -> Right (x == y)
  (VString x, VString y) -> Right (x == y)
  (VRecord fs, VRecord gs) ->
    let fs' = Map.toList (Map.fromList fs)
        gs' = Map.toList (Map.fromList gs)
     in if map fst fs' /= map fst gs'
          then Right False
          else and <$> traverse (uncurry valueEq) (zip (map snd fs') (map snd gs'))
  (VList xs, VList ys)
    | length xs /= length ys -> Right False
    | otherwise -> and <$> traverse (uncurry valueEq) (zip xs ys)
  (VVariant t1 m1, VVariant t2 m2)
    | t1 /= t2 -> Right False
    | otherwise -> case (m1, m2) of
        (Nothing, Nothing) -> Right True
        (Just x, Just y) -> valueEq x y
        _ -> Right False
  (VUnit, _) -> Right False
  (VBool {}, _) -> Right False
  (VInt {}, _) -> Right False
  (VFloat {}, _) -> Right False
  (VString {}, _) -> Right False
  (VRecord {}, _) -> Right False
  (VList {}, _) -> Right False
  (VVariant {}, _) -> Right False

arityOrType :: Text -> Int -> [Value] -> Either EvalError Value
arityOrType name n args
  | length args /= n =
      Left (Trap ("wrong arity for " <> name <> ": expected " <> T.pack (show n)))
  | otherwise = Left (Trap ("type mismatch for " <> name))
