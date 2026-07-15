-- | Parse a @```pml@ fence body into declarations + optional trailing expr.
module Pml.Parse.Module
  ( moduleBody,
    parseModuleBody,
  )
where

import Data.Text (Text)
import Data.Void (Void)
import Pml.Ast.Decl (Decl (..), ModuleBody (..))
import Pml.Ast.Expr (Param (..))
import Pml.Parse.Expr (expr)
import Pml.Parse.Lexer
import Pml.Parse.Type (typeExpr)
import Text.Megaparsec

parseModuleBody :: FilePath -> Text -> Either (ParseErrorBundle Text Void) ModuleBody
parseModuleBody = runP moduleBody

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
  pKeyword "type"
  n <- pTypeName
  _ <- symbol "="
  DType n <$> typeExpr

funDecl :: Parser Decl
funDecl = do
  pKeyword "fun"
  n <- pIdent
  ps <- paramList
  mt <- optional (symbol ":" *> typeExpr)
  _ <- symbol "="
  DFun n ps mt <$> expr

paramList :: Parser [Param]
paramList = between (symbol "(") (symbol ")") (param `sepBy` symbol ",")

param :: Parser Param
param = do
  n <- pIdent
  mt <- optional (symbol ":" *> typeExpr)
  pure (Param n mt)
