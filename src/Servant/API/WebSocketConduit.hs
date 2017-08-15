{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Servant.API.WebSocketConduit where

import Control.Concurrent                         (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async                   (race_)
import Control.Monad                              (forever, (>=>))
import Control.Monad.Catch                        (handle)
import Control.Monad.IO.Class                     (liftIO)
import Control.Monad.Trans.Resource               (ResourceT, runResourceT)
import Data.Aeson                                 (FromJSON, ToJSON, decode, encode)
import Data.ByteString.Lazy                       (fromStrict)
import Data.Conduit                               (Conduit, runConduitRes, yieldM, (.|))
import Data.Proxy                                 (Proxy (..))
import Data.Text                                  (Text)
import Network.Wai.Handler.WebSockets             (websocketsOr)
import Network.WebSockets                         (ConnectionException, acceptRequest, defaultConnectionOptions,
                                                   forkPingThread, receiveData, receiveDataMessage, sendClose,
                                                   sendTextData)
import Servant.Server                             (HasServer (..), ServantErr (..), ServerT)
import Servant.Server.Internal.Router             (leafRouter)
import Servant.Server.Internal.RoutingApplication (RouteResult (..), runDelayed)

import qualified Data.Conduit.List as CL

data WebSocketConduit i o

instance (FromJSON i, ToJSON o) => HasServer (WebSocketConduit i o) ctx where

  type ServerT (WebSocketConduit i o) m = Conduit i (ResourceT IO) o

  route Proxy _ app = leafRouter $ \env request respond -> runResourceT $
    runDelayed app env request >>= liftIO . go request respond
   where
    go request respond (Route cond) =
      websocketsOr
        defaultConnectionOptions
        (runWSApp cond)
        (backupApp respond)
        request (respond . Route)
    go _ respond (Fail e) = respond $ Fail e
    go _ respond (FailFatal e) = respond $ FailFatal e

    runWSApp cond = acceptRequest >=> \c -> handle (\(_ :: ConnectionException) -> return ()) $ do
      forkPingThread c 10
      i <- newEmptyMVar
      race_ (forever $ receiveData c >>= putMVar i) $ do
        runConduitRes $ forever (yieldM . liftIO $ takeMVar i)
                     .| CL.mapMaybe (decode . fromStrict)
                     .| cond
                     .| CL.mapM_ (liftIO . sendTextData c . encode)
        sendClose c ("Out of data" :: Text)
        -- After sending the close message, we keep receiving packages
        -- (and drop them) until the connection is actually closed,
        -- which is indicated by an exception.
        forever $ receiveDataMessage c

    backupApp respond _ _ = respond $ Fail ServantErr { errHTTPCode = 426
                                                      , errReasonPhrase = "Upgrade Required"
                                                      , errBody = mempty
                                                      , errHeaders = mempty
                                                      }
