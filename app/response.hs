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
import qualified Data.Text as Text
import qualified Network.WebSockets as WS
import Control.Monad.Managed
-- import Control.Concurrent.Async
import MVC.Socket hiding (run)
import qualified Pipes.Prelude as Pipes
-- import MVC
import Options.Generic
import MVC.Wrap (SWrap, runMVCWrapped)
-- import qualified MVC.Prelude as MVC
import ISO

mconn :: WS.PendingConnection -> Managed WS.Connection
mconn p = managed $
  bracket
  (do
      conn <- WS.acceptRequest p
      putStrLn ("request accepted in mconn" :: Text)
      pure conn)
  (\conn -> do
      WS.sendClose conn ("Bye from mconn!" :: Text)
      putStrLn ("client closed print from mconn" :: Text))

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

auto :: IO ()
auto = clientServer def
  (clientAppAuto 0.1 ["hi",".","bye"])
  (serverAppResponse (show . Text.length))

manual :: IO ()
manual = clientServer def clientAppStdin
  (serverAppResponseQuit
   ("from server: " <>)
    (/= "x"))

data Run = Auto | Manual | Mvc deriving (Generic, Show, Eq, Read)

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
    Manual -> manual
    Mvc -> print =<< mvcClientServer

mvcClientServer :: IO (SWrap () (Either SocketComms ByteString) (Either SocketComms ByteString))
mvcClientServer = do
  aServer <- async $ mvcSocket 4 (Right "q")
  sleep 0.2
  client def (clientAppAuto 0.1 ["hi",".","bye"])
  wait aServer

mvcSocket ::
  Double ->
  Either SocketComms ByteString ->
  IO (SWrap () (Either SocketComms ByteString) (Either SocketComms ByteString))
mvcSocket n q =
  runMVCWrapped () (Pipes.takeWhile (/= q)) $ wsSocket def <> inout
  where
    inout = (,) <$> pure mempty <*> MVC.Socket.quitter n q

