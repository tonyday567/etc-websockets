{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}

module Etc.WebSockets where

import Control.Exception (bracket)
import Control.Lens
import Control.Monad.Managed
import Data.Aeson
import Data.Data
import Data.Default
import Data.Generics.Labels()
import Data.Text (Text)
import Etc
import Data.IORef
import GHC.Generics
import Protolude
import qualified Data.Text as Text
import qualified Network.WebSockets as WS

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

-- * client server debug routine

-- | default websocket receiver
receiver ::
  WS.WebSocketsData a =>
  Committer (Either SocketComms a) ->
  WS.Connection ->
  IO ()
receiver c conn = forever $ do
  msg <- WS.receive conn
  case msg of
    WS.ControlMessage (WS.Close w b) ->
      commit c (Left (SocketLog $
        "received close message: " <> show w <> " " <> show b))
    WS.ControlMessage _ -> pure ()
    WS.DataMessage _ _ _ msg' -> commit c (Right (WS.fromDataMessage msg'))

-- | default websocket sender
sender ::
  WS.WebSocketsData a =>
  Box SocketComms (Either SocketComms a) ->
  WS.Connection ->
  IO ()
sender (Box c e) conn = forever $ do
  msg <- emit e
  case msg of
    Right msg' -> WS.sendTextData conn msg'
    Left comm -> commit c (SocketLog $ "sender received" <> show comm)

-- | a receiver that immediately responds
responder ::
  WS.WebSocketsData a =>
  (a -> Either SocketComms a) ->
  -- transformation of the incoming data
  Committer SocketComms ->
  -- logging and comms
  WS.Connection ->
  IO ()
responder f c conn = forever $ do
  msg <- WS.receive conn
  case msg of
    WS.ControlMessage (WS.Close w b) ->
      commit c (SocketLog $
        "received close message: " <> show w <> " " <> show b)
    WS.ControlMessage _ -> pure ()
    WS.DataMessage _ _ _ msg' -> case f $ WS.fromDataMessage msg' of
      Right a -> WS.sendTextData conn a
      Left CloseSocket -> WS.sendClose conn ("responder peer sent close" :: Text)
      Left _ -> mempty

-- | send a list of text with an intercalated delay effect
listSender ::
  Double ->
  [Text] ->
  Committer SocketComms ->
  WS.Connection ->
  IO ()
listSender n ts c conn = do
  sequence_ $
    (\line -> do
        sleep n
        commit c (SocketLog $ "listSender mailing " <> line)
        WS.sendTextData conn line) <$> ts
  commit c (SocketLog "listSender finished")
  commit c CloseSocket

-- | clientApp with the default receiver and a bespoke sender function
clientApp ::
  (Committer SocketComms -> WS.ClientApp ()) ->
  Committer (Either SocketComms Text) ->
  WS.ClientApp ()
clientApp sender' c conn = void $ concurrently
  (receiver c conn)
  (sender' (contramap Left c) conn)

-- | server app with functional responder
serverApp ::
  WS.WebSocketsData a =>
  (Committer SocketComms -> WS.Connection -> IO ()) ->
  Committer (Either SocketComms a) ->
  WS.PendingConnection ->
  IO ()
serverApp sender' c p = with (mconn p) (sender' (contramap Left c))

-- | an effect that can be started and stopped
-- committer is an existence test
controlBox ::
  IO () ->
  Box Bool ControlComms ->
  IO ()
controlBox app (Box c e) = go =<< newIORef Nothing
  where
    go :: IORef (Maybe (Async ())) -> IO ()
    go ref = do
      msg <- emit e
      case msg of
        Exists -> do
          a <- readIORef ref
          commit c $ bool True False (isNothing a)
          go ref
        Start -> do
          a <- readIORef ref
          when (isNothing a) (start ref)
          go ref
        Stop ->
          cancel' ref >> go ref
        Destroy -> cancel' ref
        Reset -> do
          a <- readIORef ref
          when (not $ isNothing a) (cancel' ref)
          start ref
          go ref
        NoOpCC -> go ref
    start ref = do
      a' <- async app
      writeIORef ref (Just a')
    cancel' ref = do
      mapM_ cancel =<< readIORef ref
      writeIORef ref Nothing

-- | single client with SocketComms messaging
clientBox ::
  ConfigSocket ->
  (Committer (Either SocketComms Text) -> WS.ClientApp ()) ->
  Box (Either SocketComms Text) SocketComms ->
  IO ()
clientBox cfg app (Box c e) =
  controlBox (client cfg (app c))
  (Box (contramap
        (bool
         (Left (SocketLog "clientBox not ok"))
         (Left (SocketLog "clientBox ok"))) c) (toSC <$> e))  where
    toSC StartClient = Start
    toSC CloseClient = Stop
    toSC ServerClosed = Destroy
    toSC CheckClient = Exists
    toSC Nuke = Destroy
    toSC _ = NoOpCC

-- | controlled server
serverBox ::
  ConfigSocket ->
  (Committer (Either SocketComms Text) -> WS.ServerApp) ->
  Box (Either SocketComms Text) SocketComms ->
  IO ()
serverBox cfg app (Box c e) =
  controlBox (server cfg (app c))
  (Box (contramap
        (bool
         (Left (SocketLog "serverBox not ok"))
         (Left (SocketLog "serverBox ok"))) c) (toSC <$> e))
  where
    toSC StartServer = Start
    toSC CloseSocket = Stop
    toSC ServerClosed = Destroy
    toSC CheckServer = Exists
    toSC Nuke = Destroy
    toSC _ = NoOpCC
