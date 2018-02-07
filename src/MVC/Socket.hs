{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module MVC.Socket where

import Data.Generics.Labels()
import Control.Concurrent.Async as Async
import Control.Exception (bracket, finally)
import Control.Lens hiding ((|>))
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
import ISO
import Flow
import qualified Streaming as S hiding (run)
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
  | ServerClosed
  | ClientClosed
  | ClientReady
  | SocketLog Text
  deriving (Show, Read, Eq, Data, Typeable, Generic)

instance FromJSON SocketComms
instance ToJSON SocketComms

client :: ConfigSocket -> WS.ClientApp () -> IO ()
client c = WS.runClient (Text.unpack $ c ^. #host) (c ^. #port) "/"

server :: ConfigSocket -> WS.ServerApp -> IO ()
server c = WS.runServer (Text.unpack $ c ^. #host) (c ^. #port)

clientServer :: ConfigSocket -> WS.ClientApp () -> WS.ServerApp -> IO ()
clientServer cfg c s = do
  as <- async (server cfg s) 
  ac <- async (do
        sleep 0.1
        client cfg c)
  wait ac
  cancel as
  putStrLn ("clientServer out" :: Text)

quitter :: Double -> a -> Managed (Controller a)
quitter n q = MVC.producer MVC.unbounded (yield q >-> Pipes.chain (\_ -> sleep n))

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

wsSocket' ::
     ConfigSocket
  -> Managed (Relator
             (Either SocketComms ByteString)
             (Either SocketComms ByteString))
wsSocket' cfg = managed $ \k -> do
  -- withBuffer unbounded (\c -> ) (\e -> )
  -- aRunner <- async $ run cfg handler
  -- (void . atomically . send oC) (Left ServerReady)
  committer <- undefined
  emitter <- undefined
  result <- k ((Relator (Committer committer) (Emitter emitter)))
  -- cancel aRunner
  return result

handler ::
  (WS.WebSocketsData a) =>
  WS.PendingConnection ->
  Managed (Relator (Either SocketComms a) (Either SocketComms a)) ->
  IO ()
handler pending r = do
  let c = (\(Relator c _) -> c) <$> r
  let e = (\(Relator _ e) -> e) <$> r
  with (managed (withConnection pending)) $ \conn -> do
    aSend <- async $ fuse (wsSend conn |> toCommit) e
    aRec <- async $ fuse c (wsReceive conn |> toEmit |> fmap (fmap Right))
    link aSend
    link aRec
    void $ waitAnyCancel [aSend, aRec]
  with c $ \(Committer b) -> void $ atomically $ sendMsg b (Left ServerClosed)

wsReceive :: (WS.WebSocketsData a) => WS.Connection -> (Committer a) -> IO ()
wsReceive conn = \(Committer c) -> forever $ do
  r <- WS.receiveData conn
  atomically $ sendMsg c r

wsSend ::
  (WS.WebSocketsData a) =>
  WS.Connection ->
  Emitter (Either SocketComms a) ->
  IO ()
wsSend conn = \(Emitter e) -> forever $ do
  x <- atomically (receiveMsg e)
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
