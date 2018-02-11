{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}


-- | debugging websockets
module Main where

import Control.Monad.Managed
import Data.Default
import Data.Functor.Contravariant
import Data.Generics.Labels()
import Data.IORef
import ETC
import MVC.Socket
import Pipes.Concurrent
import Protolude
import qualified Network.WebSockets as WS
-- import Flow

-- * client server debug routine

-- | default websocket receiver
receiver ::
  WS.WebSocketsData a =>
  Committer (Either SocketComms a) ->
  WS.Connection ->
  IO ()
receiver (Committer o) conn = forever $ do
  msg <- WS.receive conn
  case msg of
    WS.ControlMessage (WS.Close w b) ->
      send' o (Left (SocketLog $
        "received close message: " <> show w <> " " <> show b))
    WS.ControlMessage _ -> pure ()
    WS.DataMessage _ _ _ msg' -> send' o (Right (WS.fromDataMessage msg'))

-- | default websocket sender
sender ::
  WS.WebSocketsData a =>
  Box SocketComms (Either SocketComms a) ->
  WS.Connection ->
  IO ()
sender (Box (Committer o) (Emitter i)) conn = forever $ do
  msg <- atomically $ recv i
  case msg of
    Nothing -> mempty
    Just (Right msg') -> WS.sendTextData conn msg'
    Just (Left comm) -> send' o (SocketLog $ "sender received" <> show comm)

-- | a receiver that immediately responds
responder ::
  WS.WebSocketsData a =>
  (a -> Either SocketComms a) ->
  -- ^ transformation of the incoming data
  Committer SocketComms ->
  -- ^ logging and comms
  WS.Connection ->
  IO ()
responder f (Committer o) conn = forever $ do
  msg <- WS.receive conn
  case msg of
    WS.ControlMessage (WS.Close w b) ->
      send' o (SocketLog $
        "received close message: " <> show w <> " " <> show b)
    WS.ControlMessage _ -> pure ()
    WS.DataMessage _ _ _ msg' -> case f $ WS.fromDataMessage msg' of
      Right a -> WS.sendTextData conn a
      Left CloseSocket -> WS.sendClose conn ("responder peer sent close" :: Text)
      Left _ -> pure ()

-- | send a list of text with an intercalated delay effect
listSender ::
  Double ->
  [Text] ->
  Committer SocketComms ->
  WS.Connection ->
  IO ()
listSender n ts (Committer o) conn = do
  sequence_ $
    (\line -> do
        sleep n
        send' o (SocketLog $ "listSender mailing " <> line)
        WS.sendTextData conn line) <$> ts
  send' o (SocketLog "listSender finished")
  send' o CloseSocket

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
controlBox app (Box (Committer o) (Emitter i)) = go =<< newIORef Nothing
  where
    go :: IORef (Maybe (Async ())) -> IO ()
    go ref = do
      msg <- atomically $ recv i
      case msg of
        Nothing -> go ref
        Just Exists -> do
          a <- readIORef ref
          send' o $ bool True False (isNothing a)
          go ref
        Just Start -> do
          a <- readIORef ref
          when (isNothing a) (start ref)
          go ref
        Just Stop ->
          cancel' ref >> go ref
        Just Destroy -> cancel' ref
        Just Reset -> do
          a <- readIORef ref
          when (not $ isNothing a) (cancel' ref)
          start ref
          go ref
        Just NoOpCC -> go ref
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


{-
controlBox received StartcontrolBox received Start

app started in an asynced threadapp started in an asynced thread

Left (SocketLog "autoClient mailing hi")
Right "hi"
Left (SocketLog "server ok")
Left (SocketLog "autoClient mailing bye")
Right "bye"
Left (SocketLog "autoClient mailing ...")
Left (SocketLog "autoClient finished")
Right "..."
^C
-}
wsDebug :: IO ()
wsDebug =
  void $ withBuffer unbounded
  (\o -> do
    send' o StartServer
    send' o StartClient
    sleep 1
    send' o CheckServer
    send' o CheckClient
    -- send' o StartClient
    sleep 1
    -- send' o CloseClient
    send' o CloseSocket
    sleep 2
    send' o Nuke)
  (\i ->
    void $ with (contramap show <$> (cStdout 1000 :: Managed (Committer Text))) $ \c' ->
      concurrently
      (clientBox def
        (clientApp (listSender 0.5 ["hi","bye","..."])) (Box c' (Emitter i)))
      (serverBox def
        (serverApp (responder qquit)) (Box c' (Emitter i))))
  where
    qquit :: Text -> Either SocketComms Text
    qquit x =
      case x of
        "q" -> Left CloseSocket
        x' -> Right x'

main :: IO ()
main = wsDebug
