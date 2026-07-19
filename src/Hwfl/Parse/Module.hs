-- | Parse a @```hwfl@ fence body into declarations + optional trailing expr.
module Hwfl.Parse.Module
  ( moduleBody,
    parseModuleBody,
    parseModuleBodyFromLine,
  )
where

import Data.Text (Text)
import Data.Void (Void)
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr (Param (..))
import Hwfl.Parse.Expr (expr)
import Hwfl.Parse.Lexer
import Hwfl.Parse.Type (typeExpr)
import Text.Megaparsec

parseModuleBody :: FilePath -> Text -> Either (ParseErrorBundle Text Void) ModuleBody
parseModuleBody = parseModuleBodyFromLine 1

-- | Parse fence content with file-absolute line numbering starting at @startLine@.
parseModuleBodyFromLine ::
  Int ->
  FilePath ->
  Text ->
  Either (ParseErrorBundle Text Void) ModuleBody
parseModuleBodyFromLine startLine = runPFromLine startLine moduleBody

moduleBody :: Parser ModuleBody
moduleBody = do
  ds <- many (try decl)
  me <- optional (try expr)
  pure (ModuleBody ds me)

decl :: Parser Decl
decl =
  choice
    [ typeDecl,
      funDecl
    ]

typeDecl :: Parser Decl
typeDecl = do
  pos <- getPos
  pKeyword "type"
  n <- pTypeName
  _ <- symbol "="
  DType pos n <$> typeExpr

funDecl :: Parser Decl
funDecl = do
  pos <- getPos
  pKeyword "fun"
  n <- pIdent
  ps <- paramList
  mt <- optional (symbol ":" *> typeExpr)
  _ <- symbol "="
  DFun pos n ps mt <$> expr

paramList :: Parser [Param]
paramList = between (symbol "(") (symbol ")") (param `sepBy` symbol ",")

param :: Parser Param
param = do
  n <- pIdent
  mt <- optional (symbol ":" *> typeExpr)
  pure (Param n mt)
