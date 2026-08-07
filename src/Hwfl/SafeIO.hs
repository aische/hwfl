-- | Locale-independent, contained filesystem reads for user-supplied files.
module Hwfl.SafeIO
  ( ReadError (..),
    renderReadError,
    readBytesFile,
    readUtf8File,
    listDirectorySafe,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (listDirectory)
import System.IO.Error
  ( isDoesNotExistError,
    isPermissionError,
  )

data ReadError
  = ReadNotFound FilePath
  | ReadPermissionDenied FilePath
  | ReadNotAFile FilePath
  | ReadIoFailure FilePath
  | ReadInvalidUtf8 FilePath
  deriving stock (Eq, Show)

-- | Stable, English diagnostics. Do not render 'IOException': its text is
-- platform- and locale-dependent and unsuitable for machine-facing APIs.
renderReadError :: ReadError -> Text
renderReadError = \case
  ReadNotFound path -> "file not found: " <> T.pack path
  ReadPermissionDenied path -> "permission denied reading: " <> T.pack path
  ReadNotAFile path -> "expected a file but found a directory: " <> T.pack path
  ReadIoFailure path -> "could not read file: " <> T.pack path
  ReadInvalidUtf8 path -> "file is not valid UTF-8: " <> T.pack path

readBytesFile :: FilePath -> IO (Either ReadError ByteString)
readBytesFile path = do
  result <- try (BS.readFile path) :: IO (Either IOException ByteString)
  pure $ either (Left . classify path) Right result

readUtf8File :: FilePath -> IO (Either ReadError Text)
readUtf8File path = do
  bytes <- readBytesFile path
  pure $ do
    raw <- bytes
    either (const (Left (ReadInvalidUtf8 path))) Right (TE.decodeUtf8' raw)

listDirectorySafe :: FilePath -> IO (Either ReadError [FilePath])
listDirectorySafe path = do
  result <- try (listDirectory path) :: IO (Either IOException [FilePath])
  pure $ either (Left . classify path) Right result

classify :: FilePath -> IOException -> ReadError
classify path err
  | isDoesNotExistError err = ReadNotFound path
  | isPermissionError err = ReadPermissionDenied path
  | otherwise = ReadIoFailure path
