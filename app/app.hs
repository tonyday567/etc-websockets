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

import Control.Category (id)
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

testRunManual :: ConfigSocket -> IO ()
testRunManual cfg = do
  void $ with box $ \b ->
        concurrently
          (serverBox cfg (serverApp (responder Right)) b)
          (clientBox cfg (clientAppWith sender) b)
    where
      box :: Cont IO (Box (STM IO) (Either ControlResponse Text) (Either ControlRequest Text)) =
        Box <$> showStdout <*> readStdin

main :: IO ()
main = do
  void $ testRunManual defaultConfigSocket
