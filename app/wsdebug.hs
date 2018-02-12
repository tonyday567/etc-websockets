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
import Etc
import Etc.WebSockets
import Protolude
import qualified Network.WebSockets as WS

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

{-1
server received: 1
from server: 1
2
server received: 2
from server: 2
q
client thread out
wsdebug: ConnectionClosed
clientServer out
-}
manual :: IO ()
manual = clientServer def clientAppStdin
  (serverAppResponseQuit
   ("from server: " <>)
    (/= "x"))

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


clientServer :: ConfigSocket -> WS.ClientApp () -> WS.ServerApp -> IO ()
clientServer cfg c s = do
  ts <- async (server cfg s >> putStrLn ("server thread out" :: Text)) 
  tc <- async (sleep 0.1 >> client cfg c >> putStrLn ("client thread out" :: Text))
  wait tc
  sleep 1
  cancel ts
  putStrLn ("clientServer out" :: Text)

main :: IO ()
main = manual
