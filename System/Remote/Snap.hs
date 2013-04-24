{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module System.Remote.Snap
    ( startServer
    , monitor
    ) where

import Control.Applicative ((<$>), (<|>))
import Control.Monad (guard, join)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Aeson.Types as A
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import qualified Data.HashMap.Strict as M
import Data.IORef (IORef)
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, listToMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Prelude hiding (read)
import Snap.Core (MonadSnap, Request, Snap, finishWith, getHeaders, getRequest,
                  getResponse, method, Method(GET), modifyResponse, pass, route,
                  rqParams, rqPathInfo, setContentType, setResponseStatus,
                  writeBS, writeLBS, setResponseCode, setContentLength, )
import Snap.Http.Server (httpServe)
import qualified Snap.Http.Server.Config as Config
import Snap.Util.FileServe (defaultMimeTypes)
import System.FilePath (takeExtension)

import System.Remote.Common
import Data.FileEmbed (embedDir)


------------------------------------------------------------------------

startServer :: IORef Counters -> IORef Gauges -> IORef Labels
            -> S.ByteString  -- ^ Host to listen on (e.g. \"localhost\")
            -> S.ByteString  -- ^ Address to bind to (e.g., \"127.0.0.1\")
            -> Int           -- ^ Port to listen on (e.g. 8000)
            -> IO ()
startServer counters gauges labels host bindAddr port = do
    let conf = Config.setVerbose False $
               Config.setErrorLog Config.ConfigNoLog $
               Config.setAccessLog Config.ConfigNoLog $
               Config.setPort port $
               Config.setHostname host $
               Config.setBind bindAddr $
               Config.defaultConfig
    httpServe conf (monitor counters gauges labels)

-- | The routes of the ekg monitor. They do not include the routes for its
-- assets.
monitorRoutes :: MonadSnap m
              => IORef Counters -> IORef Gauges -> IORef Labels
              -> [(S8.ByteString, m ())]
monitorRoutes counters gauges labels =
    [ ("",               jsonHandler $ serveAll counters gauges labels)
    , ("combined",       jsonHandler $ serveCombined counters gauges labels)
    , ("counters",       jsonHandler $ serveMany counters)
    , ("counters/:name", textHandler $ serveOne counters)
    , ("gauges",         jsonHandler $ serveMany gauges)
    , ("gauges/:name",   textHandler $ serveOne gauges)
    , ("labels",         jsonHandler $ serveMany labels)
    , ("labels/:name",   textHandler $ serveOne labels)
    ]
  where
    jsonHandler = wrapHandler "application/json"
    textHandler = wrapHandler "text/plain"
    wrapHandler fmt handler = method GET $ format fmt $ do
        req <- getRequest
        -- We only want to handle completely matched paths.
        if S.null (rqPathInfo req) then handler else pass

-- | A handler that can be installed into an existing Snap application.
monitor :: IORef Counters -> IORef Gauges -> IORef Labels -> Snap ()
monitor counters gauges labels =
    route (monitorRoutes counters gauges labels) <|> serveAssets

-- | The Accept header of the request.
acceptHeader :: Request -> Maybe S.ByteString
acceptHeader req = S.intercalate "," <$> getHeaders "Accept" req

-- | Runs a Snap monad action only if the request's Accept header
-- matches the given MIME type.
format :: MonadSnap m => S.ByteString -> m a -> m a
format fmt action = do
    req <- getRequest
    let acceptHdr = (List.head . parseHttpAccept) <$> acceptHeader req
    case acceptHdr of
        Just hdr | hdr == fmt -> action
        _ -> pass

-- | Serve a collection of counters or gauges, as a JSON object.
serveMany :: (Ref r t, A.ToJSON t, MonadSnap m)
          => IORef (M.HashMap T.Text r) -> m ()
serveMany mapRef = do
    modifyResponse $ setContentType "application/json"
    bs <- liftIO $ buildMany mapRef
    writeLBS bs
{-# INLINABLE serveMany #-}

-- | Serve all counter, gauges and labels, built-in or not, as a
-- nested JSON object.
serveAll :: MonadSnap m
         => IORef Counters -> IORef Gauges -> IORef Labels -> m ()
serveAll counters gauges labels = do
    modifyResponse $ setContentType "application/json"
    bs <- liftIO $ buildAll counters gauges labels
    writeLBS bs

-- | Serve all counters and gauges, built-in or not, as a flattened
-- JSON object.
serveCombined :: MonadSnap m
              => IORef Counters -> IORef Gauges -> IORef Labels -> m ()
serveCombined counters gauges labels = do
    modifyResponse $ setContentType "application/json"
    bs <- liftIO $ buildCombined counters gauges labels
    writeLBS bs

-- | Serve a single counter, as plain text.
serveOne :: (Ref r t, Show t, MonadSnap m)
         => IORef (M.HashMap T.Text r) -> m ()
serveOne refs = do
    modifyResponse $ setContentType "text/plain"
    req <- getRequest
    let mname = T.decodeUtf8 <$> join
                (listToMaybe <$> Map.lookup "name" (rqParams req))
    case mname of
        Nothing -> pass
        Just name -> do
            mbs <- liftIO $ buildOne refs name
            case mbs of
                Just bs -> writeBS bs
                Nothing -> do
                    modifyResponse $ setResponseStatus 404 "Not Found"
                    r <- getResponse
                    finishWith r
{-# INLINABLE serveOne #-}

-- | Serve the embedded assets.
serveAssets :: MonadSnap m => m ()
serveAssets = serveEmbeddedFiles $(embedDir "assets")


-- | Serve a list of files under the given filepaths while selecting the MIME
--type using the 'defaultMimeMap'.
serveEmbeddedFiles :: MonadSnap m => [(FilePath, S8.ByteString)] -> m ()
serveEmbeddedFiles files = do
      route (concatMap mkAssetRoutes files)
    where
      mkAssetRoutes (path, content) =
              do return (S8.pack path, handler)
          <|> do guard (path == "index.html")
                 return (S8.empty, handler)
        where
          err  = error $ "Failed to determine MIME type of '" ++ path ++ "'"
          mime = fromMaybe err $
                     M.lookup (takeExtension path) defaultMimeTypes
          handler = do
              modifyResponse
                $ setContentType mime
                . setContentLength (fromIntegral $ S8.length content)
                . setResponseCode 200
              writeBS content
