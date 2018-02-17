{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
  
-- | debugging websockets
module Main where

import Control.Lens
import Control.Monad.Managed
import Data.Default
import Data.Generics.Labels()
import Etc
import Etc.WebSockets
import Protolude
import qualified Data.Text as Text
import qualified Pipes.Concurrent as P

{-
# $(stack path --local-install-root)/bin/wsdebug
Left (SocketLog "clientBox ok")
Left (SocketLog "listSender mailing hi")
Left (SocketLog "responder received: Text \"hi\" Nothing")
Right "echo: hi"
Left (SocketLog "received: echo: hi")
Left (SocketLog "responder sent: echo: hi")
Left (SocketLog "listSender mailing bye")
Left (SocketLog "responder received: Text \"bye\" Nothing")
Left (SocketLog "responder sent: echo: bye")
Right "echo: bye"
Left (SocketLog "received: echo: bye")
Left (SocketLog "listSender mailing ...")
Left (SocketLog "responder received: Text \"...\" Nothing")
Left (SocketLog "responder sent: echo: ...")
Right "echo: ..."
Left (SocketLog "received: echo: ...")
Left (SocketLog "listSender mailing msg: hi from the list")
Left (SocketLog "responder received: Text \"msg: hi from the list\" Nothing")
Left (SocketLog "listSender mailing q")
Left (SocketLog "listSender finished")
Left (ClientComm Closed)
Left (SocketLog "responder received: Text \"q\" Nothing")
wsdebug: CloseRequest 1000 "client requested stop"
-}
wsDebug :: ConfigSocket -> IO ()
wsDebug cfg = buff (P.bounded 1)
  (\c -> do
    commit c (ServerComm Start)
    commit c (ClientComm Start)
    commit c (ServerComm Exists) -- absent
    commit c (ClientComm Exists) -- logs ok
    sleep 2
    commit c (ServerComm Destroy)
    commit c (ClientComm Destroy))
  (\e ->
    void $ with (contramap show <$> (cStdout 1000 (P.bounded 1) :: Managed (Committer Text))) $ \c' ->
      concurrently
      (serverBox cfg
        (serverApp (responder qquit)) (rmap Left $ Box c' e))
      (clientBox cfg
        (clientAppWith
         (listSender 0.1
          ["hi","bye","...", "msg: hi from the list", "q"] . committer))
        (Box c' (fmap Left e))))
  where
    qquit :: Text -> Either SocketComm Text
    qquit x =
      case x of
        "q" -> Left (ServerComm Stop)
        "x" -> Left (ClientComm Stop)
        x' -> if "msg" `Text.isPrefixOf` x'
          then Left (SocketLog x')
          else Right ("echo: " <> x')

main :: IO ()
main = wsDebug (#port .~ 3566 $ def)
