{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Main where

-- import Control.Lens
import Data.Default
import Data.Generics.Labels()
import Protolude
import qualified Network.WebSockets as WS
import Control.Monad.Managed
-- import Control.Concurrent.Async
import MVC.Socket hiding (run)
import qualified Pipes.Prelude as Pipes
import MVC
import Options.Generic
import ETC
import qualified Streaming.Prelude as S
import qualified Pipes.Concurrent as P
-- import qualified Pipes.Prelude as P
import Data.IORef

send' :: Output a -> a -> IO ()
send' o = void . atomically . send o

mconn :: WS.PendingConnection -> Managed WS.Connection
mconn p = managed $
  bracket
  (WS.acceptRequest p)
  (\conn -> WS.sendClose conn ("Bye from mconn!" :: Text))

serverAppResponse :: (Text -> Text) -> WS.ServerApp
serverAppResponse f pending =
  with (mconn pending) $ \c ->
    -- WS.forkPingThread conn 30
    responseServer f c

serverAppResponseQuit :: (Text -> Text) -> (Text -> Bool) -> WS.ServerApp
serverAppResponseQuit f q pending =
  with (mconn pending) $ \c ->
    -- WS.forkPingThread conn 30
    responseQuitServer f q c

responseServer :: (Text -> Text) -> WS.Connection -> IO ()
responseServer f c = forever $ do
  msg :: Text <- WS.receiveData c
  putStrLn $ "message received: " <> msg
  WS.sendTextData c (f msg)

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

clientList :: Double -> [Text] -> WS.ClientApp ()
clientList n ts conn = do

  -- Fork a thread that writes server output to stdout
  aWriter <- async $ forever $ do
      msg :: Text <- WS.receiveData conn
      liftIO $ putStrLn ("clientList received: " <> msg)

  -- send the list elements with an intercalated delay effect
  sequence_ $ (\line -> do
    sleep n
    WS.sendTextData conn line) <$> ts

  -- and close
  WS.sendClose conn ("clientList out" :: Text)
  sleep 1
  cancel aWriter

waitCancel :: IO b -> IO a -> IO b
waitCancel a b =
      withAsync a $ \a' ->
      withAsync b $ \b' -> do
      a'' <- wait a'
      cancel b'
      pure a''

withBuffer' :: Buffer a -> (Input a -> IO i) -> (Output a -> IO r) -> IO r
withBuffer' b c e = withSpawn b
  (\(i,o) ->
     waitCancel
     (e i)
     (c o)
  )

-- * client server debug routine

-- | functional response to client texts
serverApp ::
  (Text -> Text) ->
  (Text -> Bool) ->
  Committer (Either SocketComms Text) ->
  WS.PendingConnection ->
  IO ()
serverApp f q (Committer c) p = with (mconn p) $ \conn ->
  void $ withBuffer P.unbounded (eio conn) (cio conn)
  where
    eio conn o = forever $ do
      msg :: Text <- WS.receiveData conn
      send' c (Left (SocketLog $ "eio serverResponse received: " <> msg))
      atomically $ send o msg
    cio conn i = loopa
      where
        loopa = do
          msg <- atomically $ recv i
          case msg of
            Nothing -> loopa
            Just msg' -> case q msg' of
              True -> do
                WS.sendTextData conn (f msg')
                send' c
                  (Left (SocketLog $
                         "serverResponse: received from buffer: " <> msg'))
                loopa
              False -> do
                WS.sendClose conn ("server out" :: Text)
                send' c
                  (Left (SocketLog $
                         "serverResponse: received client quit from buffer: "
                         <> msg'))
                loopa

-- server, with SocketComms messaging
serverBox ::
  ConfigSocket ->
  (Committer (Either SocketComms Text) -> WS.ServerApp) ->
  Box (Either SocketComms Text) SocketComms ->
  IO ()
serverBox cfg app (Box (Committer c) (Emitter e)) = do
  ref <- newIORef Nothing
  loop' ref
  where
    loop' :: IORef (Maybe (Async ())) -> IO ()
    loop' ref = do
      msg <- atomically $ recv e
      case msg of
        Nothing -> pure ()
        Just StartServer -> do
          ac' <- readIORef ref
          when (isNothing ac') serverio
          loop' ref
        Just CloseSocket -> cancel'
        _ -> loop' ref
        where
          serverio = do
            ac <- async $ do
              send' c (Left (SocketLog "main server starting"))
              server cfg (app (Committer c))
              send' c (Left $ SocketLog "should never get here")
            writeIORef ref (Just ac)
            send' c (Left ServerReady)
          cancel' = do
            mapM_ cancel =<< readIORef ref
            writeIORef ref Nothing
            send' c (Left ServerClosed)

-- | send a list of text with an intercalated delay effect
clientApp :: Double -> [Text] -> Committer (Either SocketComms Text) -> WS.ClientApp ()
clientApp n ts (Committer c) conn = void $ concurrently
  (forever $ do
      msg <- WS.receive conn
      case msg of
        WS.ControlMessage (WS.Close w b) -> send' c (Left (SocketLog $ "autoClient received close message: " <> show w <> " " <> show b))
        WS.ControlMessage _ -> pure ()
        WS.DataMessage _ _ _ msg' -> send' c (Right (WS.fromDataMessage msg')))

  (do
      sequence_ $
        (\line -> do
          sleep n
          send' c (Left (SocketLog $ "autoClient mailing " <> line))
          WS.sendTextData conn line) <$> ts
      send' c (Left (SocketLog "autoClient finished"))
  )
      -- send' c (Left CloseSocket))
      -- WS.sendClose conn ("autoClient sendClose" :: Text))

-- | single client with SocketComms messaging
clientBox ::
  ConfigSocket ->
  (Committer (Either SocketComms Text) -> WS.ClientApp ()) ->
  Box (Either SocketComms Text) SocketComms ->
  IO ()
clientBox cfg app (Box (Committer c) (Emitter e)) = do
  ref <- newIORef Nothing
  loop' ref
  where
    loop' :: IORef (Maybe (Async ())) -> IO ()
    loop' ref = do
      msg <- atomically $ recv e
      case msg of
        Nothing -> pure ()
        Just ServerReady -> do
          ac' <- readIORef ref
          when (isNothing ac') clientio
          loop' ref
        Just ServerClosed -> cancel'
        Just CloseClient -> cancel' >> loop' ref
        Just StartClient -> cancel' >> clientio >> loop' ref
        _ -> loop' ref
        where
          clientio = do
            ac <- async $ do
              client cfg (app (Committer c))
              send' c (Left ClientClosed)
            writeIORef ref (Just ac)
            send' c (Left ClientReady)
          cancel' = do
            mapM_ cancel =<< readIORef ref
            writeIORef ref Nothing  


{-
Left ServerReady
Left (SocketLog "main server starting")
Left ClientReady
Left (SocketLog "eio serverResponse")
Left (SocketLog "autoClient mailing hi")
Left (SocketLog "eio serverResponse")
Left (SocketLog "serverResponse: receive data")
Right "test: hi"
Left (SocketLog "autoClient mailing bye")
Left (SocketLog "eio serverResponse")
response: CloseRequest 1000 "autoClient sendClose"
-}

wsDebug :: IO ()
wsDebug =
  void $ withBuffer unbounded
  (\o -> do
    send' o StartServer
    sleep 2
    send' o StartClient
    sleep 10
    send' o CloseClient
    send' o CloseSocket)
  (\i ->
    void $ with (contramap show <$> (cStdout 10 :: Managed (Committer Text))) $ \c' ->
      concurrently
      (clientBox def
        (clientApp 0.5 ["hi","bye","..."]) (Box c' (Emitter i)))
      (serverBox def (serverApp ("test: " <>) (/= "q")) (Box c' (Emitter i))))
  -- (wsClient 0.2 ["hi","bye","..."])
  -- (wsTest ("test: " <>) (/= "q"))


clientServer :: ConfigSocket -> WS.ClientApp () -> WS.ServerApp -> IO ()
clientServer cfg c s = do
  ts <- async (server cfg s >> putStrLn ("server thread out" :: Text)) 
  tc <- async (sleep 0.1 >> client cfg c >> putStrLn ("client thread out" :: Text))
  wait tc
  sleep 1
  cancel ts
  putStrLn ("clientServer out" :: Text)

{-
clientList received: test: hi
clientList received: test: bye
clientList received: test: ...
response: CloseRequest 1000 "clientList out"
client thread out
clientServer out
-}

auto :: IO ()
auto = clientServer def
  (clientAppAuto 0.1 ["hi",".","bye"])
  (wsResponse ("echo: " <>) (/= "q"))

manual :: IO ()
manual = clientServer def clientAppStdin
  (serverAppResponseQuit
   ("from server: " <>)
    (/= "x"))

data Run = Auto | AutoT | Manual | Mvc | Iso | Etc deriving (Generic, Show, Eq, Read)

newtype Opts w = Opts
    { run :: w ::: Maybe Run <?> "What type of client/server test to run"
    }
    deriving (Generic)

instance ParseRecord (Opts Wrapped)
instance ParseField Run

main :: IO ()
main = do
  o :: Opts Unwrapped <- unwrapRecord "client-server examples"
  let r = fromMaybe Auto (run o)
  case r of
    Auto -> auto
    AutoT -> wsDebug
    Manual -> manual
    Mvc -> print =<< autoClientServer (mvcSocket 1 (Right "q"))
    Iso -> print =<< autoClientServer (isoSocket 1 (Right "q"))
    Etc -> print =<< autoClientServer (etcSocket 1 (Right "q"))

autoClientServer :: IO a -> IO a
autoClientServer s = do
  aServer <- async s
  sleep 0.2
  client def (clientAppAuto 0.1 ["hi","bye","x"])
  wait aServer

mvcSocket ::
  Double ->
  Either SocketComms ByteString ->
  IO ()
mvcSocket n q =
  runMVC () (asPipe $ Pipes.takeWhile (/= q)) $ wsSocket def <> inout
  where
    inout = (,) <$> pure mempty <*> MVC.Socket.quitter n q

isoSocket ::
  Double ->
  Either SocketComms Text ->
  IO ()
isoSocket n q =
  etc () (Trans $ \s -> s & S.takeWhile (/= q)) $ runner' def <> inout
  where
    inout = Box <$> pure mempty <*> ETC.quitter n q

etcSocket ::
  Double ->
  Either SocketComms ByteString ->
  IO ()
etcSocket n q =
  etc () (Trans $ \s -> s & S.takeWhile (/= q)) $ boxSocket def <> inout
  where
    inout = Box <$> pure mempty <*> ETC.quitter n q
