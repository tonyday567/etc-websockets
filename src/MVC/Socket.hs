{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module MVC.Socket where

import Data.Generics.Labels()
import Control.Concurrent.Async as Async
import Control.Exception (bracket, finally)
import Control.Lens
import Control.Monad.Managed
import Data.Aeson
import Data.Data
import Data.Default
import qualified Data.Foldable as F
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import GHC.Generics
import MVC
import qualified MVC.Prelude as MVC
import qualified Network.Socket as S
import qualified Network.WebSockets as WS
import Pipes.Extended
import qualified Pipes.Prelude as Pipes
import Protolude
import ETC
import Flow
import qualified Streaming as S
import qualified Streaming.Prelude as S
import Streaming.Concurrent

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

quitter :: Double -> a -> Managed (Controller a)
quitter n q = MVC.producer MVC.unbounded (yield q >-> Pipes.chain (\_ -> sleep n))

mconn :: WS.PendingConnection -> Managed WS.Connection
mconn p = managed $
  bracket
  (WS.acceptRequest p)
  (\conn -> WS.sendClose conn ("Bye from mconn!" :: Text))

wsSocket ::
     ConfigSocket
  -> Managed ( View (Either SocketComms ByteString)
             , Controller (Either SocketComms ByteString))
wsSocket c =
  join $
  managed $ \k -> do
    (oC, iC, sealC) <- spawn' MVC.unbounded
    (oV, iV, sealV) <- spawn' MVC.unbounded
    let handler pending =
          with (managed (withConnection pending)) $ \conn -> do
            aC <-
              async $ do
                runEffect $
                  forever
                    (do d <- lift $ WS.receiveData conn
                        yield d) >->
                  Pipes.map Right >->
                  toOutput oC
                atomically sealC
            aV <-
              async $ do
                runEffect $
                  fromInput iV >-> until' (Left CloseSocket) >->
                  forever
                    (do x <- await
                        case x of
                          Left CloseSocket -> do
                            lift $ WS.sendClose conn ("closing" :: Text)
                            lift $ putStrLn ("CloseSocket!" :: Text)
                          Right stream -> lift $ WS.sendTextData conn stream
                          _ -> return ())
                atomically sealV
            link aV
            link aC
            _ <- waitAnyCancel [aV, aC]
            void $ atomically $ send oC (Left ServerClosed)
    aServer <- async $ run c handler
    (void . atomically . send oC) (Left ServerReady)
    result <-
      k (return (asSink (void . atomically . send oV), asInput iC)) <*
      atomically sealC <*
      atomically sealV
    cancel aServer
    return result

boxSocket ::
     ConfigSocket
  -> Managed (Box (Either SocketComms ByteString) (Either SocketComms ByteString))
boxSocket c =
  join $
  managed $ \k -> do
    (oC, iC, sealC) <- spawn' MVC.unbounded
    (oV, iV, sealV) <- spawn' MVC.unbounded
    let handler pending =
          with (managed (withConnection pending)) $ \conn -> do
            aC <-
              async $ do
                runEffect $
                  forever
                    (do d <- lift $ WS.receiveData conn
                        yield d) >->
                  Pipes.map Right >->
                  toOutput oC
                atomically sealC
            aV <-
              async $ do
                runEffect $
                  fromInput iV >-> until' (Left CloseSocket) >->
                  forever
                    (do x <- await
                        case x of
                          Left CloseSocket -> do
                            lift $ WS.sendClose conn ("closing" :: Text)
                            lift $ putStrLn ("CloseSocket!" :: Text)
                          Right stream -> lift $ WS.sendTextData conn stream
                          _ -> return ())
                atomically sealV
            link aV
            link aC
            _ <- waitAnyCancel [aV, aC]
            void $ atomically $ send oC (Left ServerClosed)
    aServer <- async $ run c handler
    (void . atomically . send oC) (Left ServerReady)
    result <-
      k (return (Box (Committer oV) (Emitter iC))) <*
      atomically sealC <*
      atomically sealV
    cancel aServer
    return result

runner' ::
  ConfigSocket ->
  Managed (Box (Either SocketComms Text) (Either SocketComms Text))
runner' cfg = (\(Box c e) -> Box c (Right <$> e)) <$> runner cfg

runner ::
  ConfigSocket ->
  Managed (Box (Either SocketComms Text) Text)
runner cfg = managed (run cfg . flip (with . handler) . (void .))

handler ::
  WS.PendingConnection ->
  Managed (Box (Either SocketComms Text) Text)
handler p =
  managed (withConnection p . flip (with . wsBox))

wsRun ::
  ConfigSocket ->
  Managed (Box (Either SocketComms Text) Text)
wsRun cfg = managed
  ( run cfg
  . flip ( with
         . (\p -> managed ( withConnection p
                          . flip (with . wsBox))))
  . (void .)
  )

wsBox ::
  (WS.WebSocketsData a) =>
  WS.Connection ->
  Managed (Box (Either SocketComms a) a)
wsBox conn = Box <$> toCommit (wsSend conn) <*> toEmit (wsReceive conn)

wsReceive :: (WS.WebSocketsData a) => WS.Connection -> Committer a -> IO ()
wsReceive conn (Committer c) = forever $ do
  r <- WS.receiveData conn
  atomically $ send c r

wsSend ::
  (WS.WebSocketsData a) =>
  WS.Connection ->
  Emitter (Either SocketComms a) ->
  IO ()
wsSend conn (Emitter e) = forever $ do
  x <- atomically (recv e)
  case x of
    Just (Left CloseSocket) ->
      WS.sendClose conn ("" :: Text)
    Just (Right msg) -> void $ WS.sendTextData conn msg
    _ -> pure ()

withConnection :: WS.PendingConnection -> (WS.Connection -> IO r) -> IO r
withConnection pending =
  bracket
    (WS.acceptRequest pending)
    (\conn -> WS.sendClose conn ("closing" :: ByteString))

withSocket :: ConfigSocket -> (S.Socket -> IO c) -> IO c
withSocket c = bracket (WS.makeListenSocket (Text.unpack $ c ^. #host) (c ^. #port)) S.close

-- * servers
runServerWith' :: ConfigSocket -> WS.ConnectionOptions -> WS.ServerApp -> IO ()
runServerWith' c opts app =
  S.withSocketsDo $ do
    sock <- WS.makeListenSocket (Text.unpack $ c ^. #host) (c ^. #port)
    _ <-
      forever $ do
        (conn, _) <- S.accept sock
        a <-
          async $
          Control.Exception.finally (runApp' conn opts app) (S.close conn)
        link a
        return ()
    S.close sock

runApp' :: S.Socket -> WS.ConnectionOptions -> WS.ServerApp -> IO ()
runApp' socket opts app = do
  pending <- WS.makePendingConnection socket opts
  app pending

run :: ConfigSocket -> WS.ServerApp -> IO r
run c app =
  with (managed (withSocket c)) $ \sock ->
    forever $
        -- TODO: top level handle
     do
      (conn, _) <- S.accept sock
      a <-
        async $
        Control.Exception.finally
          (runApp' conn WS.defaultConnectionOptions app)
          (S.close conn)
      link a
      return ()

-- clients
stdinClient :: WS.ClientApp ()
stdinClient conn = do
  putStrLn ("echoClient Connected!" :: Text)
    -- Fork a thread that writes WS data to stdout
  _ <-
    forkIO $
    forever $ do
      msg <- WS.receiveData conn
      liftIO $ Text.putStrLn msg
        -- Read from stdin and write to WS
  let loop' = do
        line <- Text.getLine
        unless (Text.null line) $ WS.sendTextData conn line >> loop'
  loop'
  WS.sendClose conn ("Bye!" :: Text)

echoClient :: WS.ClientApp ()
echoClient conn = do
  putStrLn ("." :: Text)
    -- Fork a thread that writes WS data to stdout
  a <-
    async $
    forever $ do
      WS.sendTextData conn (encode [99 :: Int])
      msg <- WS.receiveData conn :: IO ByteString
      putStrLn (".1" :: Text)
      WS.sendTextData conn msg
      putStrLn $ (".2:" :: Text) <> show msg
  link a

runClient :: ConfigSocket -> IO ()
runClient c = WS.runClient (Text.unpack $ c ^. #host) (c ^. #port) "/" echoClient

wsEchoClient ::
     ConfigSocket -> Managed (View SocketComms, Controller SocketComms)
wsEchoClient c =
  join $
  managed $ \k -> do
    ref <- newIORef Nothing
    (oV, iV, sealV) <- spawn' MVC.unbounded
    (oC, iC, sealC) <- spawn' MVC.unbounded
    aV <-
      async $ do
        runEffect $
          fromInput iV >->
          Pipes.chain
            (\x ->
               case x of
                 ServerReady -> do
                   aClient <-
                     async $
                     WS.runClient (Text.unpack $ c ^. #host) (c ^. #port) "/" echoClient
                   writeIORef ref (Just aClient)
                   (void . atomically . send oC) ClientReady
                 ServerClosed -> do
                   F.mapM_ cancel =<< readIORef ref
                   (void . atomically . send oC) ClientClosed
                 _ -> return ()) >->
          forever await
        atomically sealV
        atomically sealC
    res <-
      k (return (asSink (void . atomically . send oV), asInput iC)) <*
      atomically sealV <*
      atomically sealC
    cancel aV
    return res
