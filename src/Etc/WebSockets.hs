{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Etc.WebSockets where

import Control.Concurrent.Async as Async
import Control.Exception (bracket, finally)
import Control.Lens
import Control.Monad.Managed
import Data.Aeson
import Data.Data
import Data.Default
import Data.Generics.Labels()
import Data.IORef
import Data.Text (Text)
import Etc
import Flow
import GHC.Generics
import Protolude
import qualified Data.Foldable as F
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Network.Socket as S
import qualified Network.WebSockets as WS
import qualified Streaming as S
import qualified Streaming.Prelude as S

data ConfigSocket = ConfigSocket
  { host :: Text
  , port :: Int
  } deriving (Show, Eq, Generic)

instance Default ConfigSocket where
  def = ConfigSocket "127.0.0.1" 9160

data SocketComms
  = ServerReady
  | CloseSocket
  | CloseClient
  | ServerClosed
  | ClientClosed
  | ClientReady
  | StartClient
  | StartServer
  | SocketLog Text
  | CheckServer
  | CheckClient
  | Nuke
  deriving (Show, Read, Eq, Data, Typeable, Generic)

instance FromJSON SocketComms
instance ToJSON SocketComms

data ControlComms
  = Start
  | Stop
  | Reset
  | Destroy
  | Exists
  | NoOpCC
  deriving (Show, Read, Eq, Data, Typeable, Generic)

client :: ConfigSocket -> WS.ClientApp () -> IO ()
client c = WS.runClient (Text.unpack $ c ^. #host) (c ^. #port) "/"

server :: ConfigSocket -> WS.ServerApp -> IO ()
server c = WS.runServer (Text.unpack $ c ^. #host) (c ^. #port)

mconn :: WS.PendingConnection -> Managed WS.Connection
mconn p = managed $
  bracket
  (WS.acceptRequest p)
  (\conn -> WS.sendClose conn ("Bye from mconn!" :: Text))

