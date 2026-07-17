module Hwfl.Cli.JsonSpec (spec) where

import Data.Aeson (eitherDecodeStrict, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Project (ProjectCheckError (..))
import Hwfl.Cli.Json
  ( jsonCheckErrorAtPath,
    jsonProjectCheckError,
    jsonRuntimeError,
    renderCliError,
  )
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Source (Diagnostic (..), Pos (..))
import Test.Hspec

spec :: Spec
spec = describe "CLI JSON errors" $ do
  it "encodes a check error with path and exit code" $ do
    let txt =
          renderCliError $
            jsonCheckErrorAtPath (Just "bad.md") (UnboundVar (Ident "x"))
    parseEnvelope txt
      `shouldSatisfy` ( \env ->
          env.status == "error"
            && env.exitCode == 1
            && env.category == Just "check"
            && env.kind == Just "UnboundVar"
            && env.message == Just "unbound variable: x"
            && env.path == Just "bad.md"
      )

  it "encodes project parse diagnostics" $ do
    let txt =
          renderCliError $
            jsonProjectCheckError
              ( PceParse
                  "mod.md"
                  [Diagnostic "mod.md" (Pos 2 3) "unexpected token"]
              )
    parseEnvelope txt
      `shouldSatisfy` ( \env ->
          env.status == "error"
            && env.exitCode == 1
            && env.category == Just "parse"
            && env.path == Just "mod.md"
            && env.diagnostics == Just 1
      )

  it "encodes runtime errors with stale-project exit code" $ do
    let txt =
          renderCliError $
            jsonRuntimeError 4 (ConfigErr "stale project hash mismatch")
    parseEnvelope txt
      `shouldSatisfy` ( \env ->
          env.exitCode == 4
            && env.category == Just "runtime"
            && env.kind == Just "ConfigErr"
      )

data Envelope = Envelope
  { status :: Text,
    exitCode :: Int,
    category :: Maybe Text,
    kind :: Maybe Text,
    message :: Maybe Text,
    path :: Maybe Text,
    diagnostics :: Maybe Int
  }
  deriving stock (Eq, Show)

parseEnvelope :: Text -> Envelope
parseEnvelope txt =
  case eitherDecodeStrict (TE.encodeUtf8 txt) of
    Left err -> error ("invalid json: " <> err)
    Right v -> case parseMaybe parseEnvelopeValue v of
      Nothing -> error "missing envelope fields"
      Just env -> env

parseEnvelopeValue :: Aeson.Value -> Parser Envelope
parseEnvelopeValue =
  withObject "cli error" $ \o -> do
    status <- o .: "status"
    exitCode <- o .: "exit_code"
    category <- o .:? "category"
    kind <- o .:? "kind"
    message <- o .:? "message"
    path <- o .:? "path"
    md <- o .:? "diagnostics"
    let diagnostics =
          case md of
            Just (Aeson.Array xs) -> Just (V.length xs)
            _ -> Nothing
    pure
      Envelope
        { status,
          exitCode,
          category,
          kind,
          message,
          path,
          diagnostics
        }
