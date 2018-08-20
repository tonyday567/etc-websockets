{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase #-}

-- | debugging websockets
module Main where

import Control.Lens hiding (Wrapped, Unwrapped)
import Data.Default
import Data.Generics.Labels()
import Box
import Box.Control
import Box.WebSockets
import Protolude hiding (STM)
import qualified Streaming.Prelude as S
import Data.IORef
import Options.Generic
import Control.Monad.Conc.Class as C
import Prelude (Show)

{-
# $(stack path --local-install-root)/bin/wsdebug
c:Left (ServerComm Start)
c:Left (ClientComm Start)
c:Left (ServerComm Exists)
c:Left (SocketLog "serverBox ok")
c:Left (SocketLog "listSender mailing hi")
c:Left (SocketLog "responder received: Text \"hi\" Nothing")
c:Left (SocketLog "responder sent: hi")
c:Right "hi"
c:Left (SocketLog "received: hi")
c:Left (ClientComm Exists)
c:Left (SocketLog "clientBox ok")
c:Left (SocketLog "listSender mailing bye")
c:Left (SocketLog "responder received: Text \"bye\" Nothing")
c:Right "bye"
c:Left (SocketLog "received: bye")
c:Left (SocketLog "responder sent: bye")
c:Left (SocketLog "listSender mailing ...")
c:Left (SocketLog "listSender finished")
c:Left (ClientComm Closed)
c:Left (SocketLog "responder received: Text \"...\" Nothing")
c:Left (SocketLog "responder sent: ...")
c:Right "..."
c:Left (SocketLog "received: ...")
c:Left (ServerComm Destroy)
[ServerComm Start,ClientComm Start,ServerComm Exists,ClientComm Exists,ServerComm Destroy,ClientComm Destroy]
wsdebug: ConnectionClosed
-}

{-
cTest :: ConfigSocket -> Cont IO (Committer STM SocketComm)
cTest cfg = fuseCommit $ \e ->
  Box.with (contramap (("c:" <>) . show) <$>
                 (cStdout 100 :: Cont IO (Committer STM Text))) $ \c' -> do
      let e' = branchE (Left <$> e) c'
      snd <$> concurrently
        (serverBox cfg
         (serverApp (responder Right)) (Box c' e'))
        (clientBox cfg
         (clientAppWith
          (listSender 0.1
           ["hi","bye","..."] . committer))
         (Box c' e'))

-}

canned :: S.Stream (S.Of SocketComm) IO ()
canned = delayTimed $ S.each
  [ (2, ServerComm Start)
  , (2, ClientComm Start)
  , (2.1, ServerComm Check)
  , (2.2, ClientComm Check)
  , (6, ServerComm Kill)
  , (6, ClientComm Kill)
  ]

{-
testRun :: ConfigSocket -> IO [SocketComm]
testRun cfg = do
  ref <- newIORef []
  etc () (Transducer identity)
    (Box <$> (cTest Unbounded cfg <> cIORef ref Unbounded) <*> toEmit Unbounded canned)
  reverse <$> readIORef ref

-}

testRunManual :: ConfigSocket -> IO [SocketComm]
testRunManual cfg = do
  ref <- C.newIORef []
  ar <- async runClientServer
  etc () (Transducer identity) box
  link ar
  reverse <$> C.readIORef ref
    where
      runClientServer = with box $ \b ->
        concurrently
          (serverBox cfg (serverApp (responder Right)) (b))
          (clientBox cfg (clientAppWith sender) (b))

      box :: Cont IO (Box (STM IO) ControlComm ControlComm) =
        Box <$> (showStdout) <*> (readStdin)

{-
testRunServer :: ConfigSocket -> IO Bool
testRunServer cfg =
  with box $ \box' -> serverBox cfg (serverApp (responder Right)) (liftB box')
    where
      box =
        Box <$> (cStdout 100) <*> (fmap Right <$> eStdin 100)

-}


{-
testRunClient :: ConfigSocket -> IO ()
testRunClient cfg =
  with box $
  \box' ->
    controlBox
    (client cfg
      (app
        (Box (committer box') (keeps _Right $ emitter box'))))
    (Box (contramap ok $ committer box') (keeps (_Right . _Left . _clientComm) $
      emitter box'))
    where
      _clientComm :: Prism' SocketComm ControlComm
      _clientComm = prism ClientComm
          (\a -> case a of
              ClientComm c -> Right c
              _ -> Left a)
      ok False = Left (SocketLog "client down")
      ok True = Left (SocketLog "client up")
      app b conn = void $
        concurrently
        (receiver (committer b) conn)
        (sender (lmap Left b) conn)
      box :: Cont IO (Box STM (Either SocketComm Text)
                      (Either Text (Either SocketComm Text))) =
        Box <$> (cStdout 100) <*> (fmap Left <$> eStdin 100)

-}

data Run = Client | Server | Auto | Manual deriving (Show, Eq, Generic, Read)

instance ParseField Run

data Opts w = Opts
  { wsport :: w ::: Maybe Int <?> "number of batteries desired"
  , run :: w ::: Maybe Run <?> "manual or automatic test"
  } deriving (Generic)

instance ParseRecord (Opts Wrapped)

main :: IO ()
main = do
  o :: Opts Unwrapped <- unwrapRecord "etc-websockets"
  let p = fromMaybe (view #port (def::ConfigSocket)) (wsport o)
  let r = fromMaybe Auto (run o)
  case r of
--    Auto ->
--      void $ testRun (#port .~ p $ def)
    Manual ->
      void $ testRunManual (#port .~ p $ def)
--    Client ->
--      testRunClient (#port .~ p $ def)
--    Server ->
--      testRunServer (#port .~ p $ def)
