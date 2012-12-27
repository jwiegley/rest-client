{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import           Control.Applicative
import           Control.Monad
import           Data.Aeson
import           Data.ByteString as B hiding (pack)
import qualified Data.ByteString.Base64 as B64
import           Data.Default ( Default(..) )
import           Data.Maybe
import           Data.Monoid
import           Data.Text as T hiding (drop)
import           Data.Text.Encoding as E
import           Network.HTTP.Types
import           Network.REST.Client
import           Network.Socket
import           System.Environment
import           Text.Shakespeare.Text ( st )

data Blob = Blob { blobContent  :: ByteString
                 , blobEncoding :: Text
                 , blobSha      :: Text
                 , blobSize     :: Int } deriving Show

-- jww (2012-12-26): Create ToREST and FromREST, which encode/decode to/from
-- byte _streams_ in order to make rest-client representation agnostic, while
-- keeping the UI simple
-- jww (2012-12-26): If no name mangling scheme is provided, assume it is
-- "type name prefix"
instance FromJSON Blob where
  parseJSON (Object v) = Blob <$> v .: "content"
                              <*> v .: "encoding"
                              <*> v .: "sha"
                              <*> v .: "size"
  parseJSON _ = mzero

-- jww (2012-12-26): Use a MonadReader to pass the token, owner and repo to
-- all GitHub API calls
gitHubReadBlob :: Text -> Text -> Text -> IO (Either String ByteString)
gitHubReadBlob owner repo sha = do
  blob <- restfulGet
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/blobs/#{sha}|]
  return $ maybe (Left "Blob not found") dec (blobContent <$> blob)
  -- jww (2012-12-26): Handle utf-8 and other encodings
  where dec = B64.decode . B.concat . B.split 10
  -- jww (2012-12-26): Need to add support for passing in a Maybe Text token
  -- in order to read from private repositories

data Content = Content { contentContent  :: ByteString
                       , contentEncoding :: Text } deriving Show

instance FromJSON Content where
  parseJSON (Object v) = Content <$> v .: "content"
                                 <*> v .: "encoding"
  parseJSON _ = mzero

instance ToJSON Content where
  -- jww (2012-12-26): The content here needs to be base64
  toJSON (Content bs enc) = object ["content" .= bs, "encoding" .= enc]

instance Default Content where
  def = Content B.empty "utf-8"

data Sha = Sha { shaSha :: Text } deriving Show

instance FromJSON Sha where
  parseJSON (Object v) = Sha <$> v .: "sha"
  parseJSON _ = mzero

instance ToJSON Sha where
  toJSON (Sha sha) = object ["sha" .= sha]

gitHubWriteBlob :: Text -> Text -> Text -> ByteString -> IO (Maybe Sha)
gitHubWriteBlob token owner repo content =
  restfulPostEx (Content content "utf-8")
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/blobs|] $
    addHeader "Authorization" ("token " <> token)

data Tree = Tree { treeSha  :: Text
                 , treeTree :: [TreeEntry] }
          deriving Show

instance FromJSON Tree where
  parseJSON (Object v) = Tree <$> v .: "sha"
                              <*> v .: "tree"
  parseJSON _ = mzero

instance ToJSON Tree where
  toJSON (Tree sha tree) = if T.null sha
                           then object ["tree" .= tree]
                           else object ["sha" .= sha, "tree" .= tree]

data TreeEntry = TreeEntry { treeEntryType :: Text
                           , treeEntryPath :: Text
                           , treeEntryMode :: Text
                           , treeEntrySize :: Int
                           , treeEntrySha  :: Text }
          deriving Show

instance FromJSON TreeEntry where
  parseJSON (Object v) = TreeEntry <$> v .: "type"
                                   <*> v .: "path"
                                   <*> v .: "mode"
                                   <*> v .:? "size" .!= (-1)
                                   <*> v .: "sha"
  parseJSON _ = mzero

instance ToJSON TreeEntry where
  toJSON entry = object [ "type" .= treeEntryType entry
                        , "path" .= treeEntryPath entry
                        , "mode" .= treeEntryMode entry
                        , "sha"  .= treeEntrySha entry ]

gitHubReadTree :: Text -> Text -> Text -> IO (Maybe Tree)
gitHubReadTree owner repo sha =
  restfulGet
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/trees/#{sha}|]

gitHubWriteTree :: Text -> Text -> Text -> Tree -> IO (Maybe Tree)
gitHubWriteTree token owner repo tree =
  restfulPostEx tree
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/trees|] $
    addHeader "Authorization" ("token " <> token)

data Signature = Signature { signatureDate  :: Text
                           , signatureName  :: Text
                           , signatureEmail :: Text } deriving Show

instance FromJSON Signature where
  parseJSON (Object v) = Signature <$> v .: "date"
                                   <*> v .: "name"
                                   <*> v .: "email"
  parseJSON _ = mzero

instance ToJSON Signature where
  toJSON (Signature date name email) = object [ "date"  .= date
                                              , "name"  .= name
                                              , "email" .= email ]

data Commit = Commit { commitSha       :: Text
                     , commitAuthor    :: Signature
                     , commitCommitter :: Maybe Signature
                     , commitMessage   :: Text
                     , commitTree      :: Sha
                     , commitParents   :: [Sha] }
            deriving Show

instance FromJSON Commit where
  parseJSON (Object v) = Commit <$> v .: "sha"
                                <*> v .: "author"
                                <*> v .:? "committer"
                                <*> v .: "message"
                                <*> v .: "tree"
                                <*> v .: "parents"
  parseJSON _ = mzero

instance ToJSON Commit where
  toJSON c = object $ [ "sha"       .= commitSha c
                      , "author"    .= commitAuthor c
                      , "message"   .= commitMessage c
                      , "tree"      .= commitTree c
                      , "parents"   .= commitParents c ] <>
                      [ "committer" .= fromJust (commitCommitter c) |
                        isJust (commitCommitter c) ]

gitHubReadCommit :: Text -> Text -> Text -> IO (Maybe Commit)
gitHubReadCommit owner repo sha =
  -- jww (2012-12-26): Support inserting the method name directly before the
  -- URL.
  -- jww (2012-12-26): Do we want runtime checking of the validity of the
  -- method?  Yes, but allow the user to declare it as OK.
  restful
    [st|GET https://api.github.com/repos/#{owner}/#{repo}/git/commits/#{sha}|]

gitHubWriteCommit :: Text -> Text -> Text -> Commit -> IO (Maybe Commit)
gitHubWriteCommit token owner repo commit =
  restfulPostEx commit
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/commits|] $
    addHeader "Authorization" ("token " <> token)

data ObjectRef = ObjectRef { objectRefType :: Text
                           , objectRefSha  :: Text } deriving Show

instance FromJSON ObjectRef where
  parseJSON (Object v) = ObjectRef <$> v .: "type"
                                   <*> v .: "sha"
  parseJSON _ = mzero

instance ToJSON ObjectRef where
  toJSON c = object $ [ "type" .= objectRefType c
                      , "sha"  .= objectRefSha c ]

data Reference = Reference { referenceRef    :: Text
                           , referenceObject :: ObjectRef } deriving Show

instance FromJSON Reference where
  parseJSON (Object v) = Reference <$> v .: "ref"
                                   <*> v .: "object"
  parseJSON _ = mzero

instance ToJSON Reference where
  toJSON c = object $ [ "ref"    .= referenceRef c
                      , "object" .= referenceObject c ]

gitHubGetRef :: Text -> Text -> Text -> IO (Maybe Reference)
gitHubGetRef owner repo ref =
  restfulGet
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/#{ref}|]

gitHubGetAllRefs :: Text -> Text -> Text -> IO (Maybe [Reference])
gitHubGetAllRefs owner repo namespace =
  restfulGet
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/#{namespace}|]

gitHubCreateRef :: Text -> Text -> Text -> Reference -> IO (Maybe Reference)
gitHubCreateRef token owner repo ref =
  restfulPostEx ref
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/refs|] $
    addHeader "Authorization" ("token " <> token)

gitHubUpdateRef :: Text -> Text -> Text -> Text -> Sha -> IO (Maybe Reference)
gitHubUpdateRef token owner repo ref sha =
  restfulPostEx sha
    [st|https://api.github.com/repos/#{owner}/#{repo}/git/#{ref}|] $ do
      setMethod "PATCH"
      addQueryParam "force" True
      addHeader "Authorization" ("token " <> token)

gitHubDeleteRef :: Text -> Text -> Text -> Text -> IO ()
gitHubDeleteRef token owner repo ref = undefined

main :: IO ()
main = withSocketsDo $ do
  [token] <- getArgs

  let sha = "3340a84bddc2c1a945b4e1ad232f4e1d0ae2a2dc"
  print =<< gitHubReadBlob "fpco" "gitlib" sha
  print =<< gitHubWriteBlob (pack token) "fpco" "gitlib"
                            (E.encodeUtf8 "Hello, world!")

  print =<< gitHubReadTree "fpco" "gitlib"
                           "d2ce27a394f9fa8ce5a83fb52405a2701feeadd3"
  let tree =
        Tree { treeSha = ""
             , treeTree = [
                  TreeEntry { treeEntryType = "blob"
                            , treeEntryMode = "100644"
                            , treeEntryPath = "sample"
                            , treeEntrySha  = sha
                            , treeEntrySize = (-1) } ] }
  print =<< gitHubWriteTree (pack token) "fpco" "gitlib" tree

  let csha = "a3f4494be204612f7bd526d65cd8db587e32c46d"
  print =<< gitHubReadCommit "fpco" "gitlib" csha

-- GitHub.hs
