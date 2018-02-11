{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

-- | debugging websockets
module Main where

import Control.Monad.Managed
import Data.Default
import Data.Functor.Contravariant
import Data.Generics.Labels()
import Data.IORef
import Etc
import Etc.WebSockets
import Protolude
import qualified Network.WebSockets as WS

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
  -- ^ transformation of the incoming data
  Committer SocketComms ->
  -- ^ logging and comms
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
wsDebug = buff
  (\c -> do
    commit c StartServer
    commit c StartClient
    sleep 1
    commit c CheckServer
    commit c CheckClient
    -- commit c StartClient
    sleep 1
    -- commit c CloseClient
    commit c CloseSocket
    sleep 2
    commit c Nuke)
  (\e ->
    void $ with (contramap show <$> (cStdout 1000 :: Managed (Committer Text))) $ \c' ->
      concurrently
      (clientBox def
        (clientApp (listSender 0.5 ["hi","bye","..."])) (Box c' e))
      (serverBox def
        (serverApp (responder qquit)) (Box c' e)))
  where
    qquit :: Text -> Either SocketComms Text
    qquit x =
      case x of
        "q" -> Left CloseSocket
        x' -> Right x'

main :: IO ()
main = wsDebug

auto :: IO ()
auto = clientServer def
  (clientAppAuto 0.1 ["hi",".","bye"])
  (wsResponse ("echo: " <>) (/= "q"))

wsResponse :: (Text -> Text) -> (Text -> Bool) -> WS.PendingConnection -> IO ()
wsResponse f q p = with (mconn p) loop'
  where
    loop' c = do
      msg :: Text <- WS.receiveData c
      case q msg of
        True -> WS.sendTextData c (f msg) >> loop' c
        False -> do
          WS.sendClose c ("server out" :: Text)
          sleep 2
          putStrLn ("server out" :: Text)

clientAppAuto :: Double -> [Text] -> WS.ClientApp ()
clientAppAuto n ts conn = do
  putStrLn ("Hello from auto!" :: Text)

  -- Fork a thread that writes server output to stdout
  aWriter <- async $ forever $ do
      msg :: Text <- WS.receiveData conn
      liftIO $ putStrLn ("clientAppAuto received: " <> msg)
  sequence_ $ (\line -> do
    sleep n
    WS.sendTextData conn line) <$> ts
  WS.sendClose conn ("Bye from auto!" :: Text)
  cancel aWriter

manual :: IO ()
manual = clientServer def clientAppStdin
  (serverAppResponseQuit
   ("from server: " <>)
    (/= "x"))

serverAppResponseQuit :: (Text -> Text) -> (Text -> Bool) -> WS.ServerApp
serverAppResponseQuit f q pending =
  with (mconn pending) $ \c ->
    -- WS.forkPingThread conn 30
    responseQuitServer f q c

responseQuitServer :: (Text -> Text) -> (Text -> Bool) -> WS.Connection -> IO ()
responseQuitServer f q c = loop'
  where
    loop' = do
      msg :: Text <- WS.receiveData c
      putStrLn $ "server received: " <> msg
      when (q msg) $ WS.sendTextData c (f msg) >> loop'

clientAppStdin :: WS.ClientApp ()
clientAppStdin conn = do
  -- Fork a thread that writes server output to stdout
  aWriter <- async $ forever $ do
      msg :: Text <- WS.receiveData conn
      liftIO $ putStrLn msg
  loop'
  cancel aWriter
  where
    loop' = do
        line <- getLine
        unless ("q" == line) $ WS.sendTextData conn line >> loop'

clientServer :: ConfigSocket -> WS.ClientApp () -> WS.ServerApp -> IO ()
clientServer cfg c s = do
  ts <- async (server cfg s >> putStrLn ("server thread out" :: Text)) 
  tc <- async (sleep 0.1 >> client cfg c >> putStrLn ("client thread out" :: Text))
  wait tc
  sleep 1
  cancel ts
  putStrLn ("clientServer out" :: Text)
