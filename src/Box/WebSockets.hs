{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell #-}

module Box.WebSockets where

import Control.Exception (bracket)
import Control.Lens
import Control.Monad.Managed
import Data.Data
import Data.Default
import Data.Generics.Labels()
import Data.Text (Text)
import Box
import Box.Control
import Box.Time (sleep)
import GHC.Generics
import Protolude hiding (STM)
import qualified Data.Text as Text
import qualified Network.WebSockets as WS
import Control.Monad.Conc.Class

data ConfigSocket = ConfigSocket
  { host :: Text
  , port :: Int
  } deriving (Show, Eq, Generic)

instance Default ConfigSocket where
  def = ConfigSocket "127.0.0.1" 9160

data SocketComm
  = ServerComm ControlComm
  | ClientComm ControlComm
  | SocketLog Text
  deriving (Show, Read, Eq, Data, Typeable, Generic)

makePrisms ''SocketComm

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
  Committer IO (Either SocketComm Text) ->
  WS.Connection ->
  IO ()
receiver c conn = forever $ do
  msg <- WS.fromDataMessage <$> WS.receiveDataMessage conn
  _ <- commit c (Right msg)
  commit c (Left (SocketLog $ "received: " <> msg))

receiver' ::
  WS.WebSocketsData a =>
  Committer IO (Either SocketComm a) ->
  WS.Connection ->
  IO Bool
receiver' c conn = go where
  go = do
    msg <- WS.receive conn
    case msg of
      WS.ControlMessage (WS.Close w b) ->
        commit c
        (Left (SocketLog $
                "received close message: " <> show w <> " " <> show b))
      WS.ControlMessage _ -> go
      WS.DataMessage _ _ _ msg' -> commit c (Right (WS.fromDataMessage msg')) >> go

-- | default websocket sender
sender ::
  WS.WebSocketsData a =>
  Box IO SocketComm (Either SocketComm a) ->
  WS.Connection ->
  IO ()
sender (Box c e) conn = forever $ do
  msg <- emit e
  case msg of
    Nothing -> pure ()
    Just msg' -> case msg' of
      Right msg'' -> WS.sendTextData conn msg''
      Left comm -> void $ commit c (SocketLog $ "sent: " <> show comm)

-- | a receiver that immediately responds
responder ::
  (Text -> Either SocketComm Text) ->
  -- transformation of the incoming data
  Committer IO SocketComm ->
  -- logging and comms
  WS.Connection ->
  IO ()
responder f c conn = go where
  go = do
    msg <- WS.receiveDataMessage conn
    _ <- commit c (SocketLog $ "responder received: " <> show msg)
    case f (WS.fromDataMessage msg) of
        Right a -> do
          WS.sendTextData conn a
          _ <- commit c (SocketLog $ "responder sent: " <> a)
          go
        Left (ServerComm Stop) ->
          WS.sendClose conn ("client requested stop" :: Text) >> go
        Left (ServerComm Kill) ->
          WS.sendClose conn ("client requested kill" :: Text)
        Left _ -> go

-- | a receiver that immediately responds
responder' ::
  WS.WebSocketsData a =>
  (a -> Either SocketComm a) ->
  -- transformation of the incoming data
  Committer IO SocketComm ->
  -- logging and comms
  WS.Connection ->
  IO ()
responder' f c conn = go where
  go = do
    msg <- WS.receive conn
    case msg of
      WS.ControlMessage (WS.Close w b) -> do
        _ <- commit c
          (SocketLog $
           "received close message: " <> show w <> " " <> show b)
        WS.sendClose conn ("returning close signal" :: Text)
        go
      WS.ControlMessage _ -> go
      WS.DataMessage _ _ _ msg' -> case f $ WS.fromDataMessage msg' of
        Right a -> WS.sendTextData conn a >> go
        Left (ServerComm Stop) -> WS.sendClose conn ("responding to close signal" :: Text) >> go
        Left _ -> go

-- | send a list of text with an intercalated delay effect
listSender ::
  Double ->
  [Text] ->
  Committer IO SocketComm ->
  WS.Connection ->
  IO ()
listSender n ts c conn = do
  sequence_ $
    (\line -> do
        sleep n
        _ <- commit c (SocketLog $ "listSender mailing " <> line)
        WS.sendTextData conn line) <$> ts
  _ <- commit c (SocketLog "listSender finished")
  _ <- commit c (ClientComm ShutDown)
  pure ()

-- | clientApp with the default receiver and sender function
clientApp ::
  Box IO (Either SocketComm Text) (Either SocketComm Text) ->
  WS.ClientApp ()
clientApp b conn = void $ concurrently
  (receiver (committer b) conn)
  (sender (lmap Left b) conn)

-- | clientApp with the default receiver and a bespoke sender function
clientAppWith ::
  (Box IO SocketComm (Either SocketComm Text) -> WS.ClientApp ()) ->
  Box IO (Either SocketComm Text) (Either SocketComm Text) ->
  WS.ClientApp ()
clientAppWith sender' b conn = void $ concurrently
  (receiver (committer b) conn)
  (sender' (lmap Left b) conn)

-- | server app with functional responder
serverApp ::
  (Committer IO SocketComm -> WS.Connection -> IO ()) ->
  Committer IO (Either SocketComm a) ->
  WS.PendingConnection ->
  IO ()
serverApp sender' c p = Control.Monad.Managed.with (mconn p) (sender' (contramap Left c))

{-

-}

-- | single client with SocketComm messaging
clientBox ::
  ConfigSocket ->
  (Box IO (Either SocketComm Text) (Either SocketComm Text) -> WS.ClientApp ()) ->
  Box (STM IO) ControlComm ControlComm ->
  IO Bool
clientBox cfg app b@(Box c e) =
  controlBox AllowDeath
  (client cfg (app (liftB $ Box (contramap fromAC c) (fmap toAC e)))) b
  where
    toAC = Left . ClientComm
    fromAC (Left (ClientComm x)) = x
    fromAC _ = Log "no op"

-- | controlled server
serverBox ::
  ConfigSocket ->
  (Committer IO (Either SocketComm Text) -> WS.ServerApp) ->
  Box (STM IO) ControlComm ControlComm ->
  IO Bool
serverBox cfg app b@(Box c _) =
  controlBox AllowDeath (server cfg (app (liftC $ contramap fromAC c))) b
  where
    fromAC (Left (ServerComm x)) = x
    fromAC _ = Log "no op"
