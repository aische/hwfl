-- | Type-expression parser (grammar TypeExpr).
module Hwfl.Parse.Type
  ( typeExpr,
    parseTypeText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type
import Hwfl.Parse.Lexer
import Text.Megaparsec

parseTypeText :: FilePath -> Text -> Either (ParseErrorBundle Text Void) TypeExpr
parseTypeText = runP typeExpr

typeExpr :: Parser TypeExpr
typeExpr = do
  left <- typeAtom
  rest <- optional typeArrow
  case rest of
    Nothing -> pure left
    Just (effs, right) ->
      pure $ case effs of
        Nothing -> TFun left right
        Just es -> TEffFun left es right

typeArrow :: Parser (Maybe [Effect], TypeExpr)
typeArrow =
  choice
    [ try $ do
        _ <- symbol "-["
        es <- effect `sepBy1` symbol ","
        _ <- symbol "]->"
        right <- typeExpr
        pure (Just es, right),
      do
        _ <- symbol "->"
        right <- typeExpr
        pure (Nothing, right)
    ]

typeAtom :: Parser TypeExpr
typeAtom =
  choice
    [ try specialized,
      TName <$> pTypeName,
      TRecord <$> recordType,
      between (symbol "(") (symbol ")") typeExpr
    ]

specialized :: Parser TypeExpr
specialized = do
  n <- pTypeName
  _ <- symbol "<"
  case unTypeName n of
    "List" -> do
      t <- typeExpr
      _ <- symbol ">"
      pure (TList t)
    "Option" -> do
      t <- typeExpr
      _ <- symbol ">"
      pure (TOption t)
    "Result" -> do
      a <- typeExpr
      _ <- symbol ","
      b <- typeExpr
      _ <- symbol ">"
      pure (TResult a b)
    "Secret" -> do
      t <- typeExpr
      _ <- symbol ">"
      pure (TSecret t)
    other -> fail ("unknown type constructor: " <> T.unpack other)

recordType :: Parser [(Ident, TypeExpr)]
recordType = do
  _ <- symbol "{"
  fs <- fieldType `sepBy` symbol ","
  _ <- symbol "}"
  pure fs

fieldType :: Parser (Ident, TypeExpr)
fieldType = do
  n <- pIdent
  _ <- symbol ":"
  t <- typeExpr
  pure (n, t)

effect :: Parser Effect
effect = do
  n <- pTypeName
  case parseEffectName (unTypeName n) of
    Just e -> pure e
    Nothing -> fail ("unknown effect: " <> T.unpack (unTypeName n))
