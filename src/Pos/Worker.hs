{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | High level workers.

module Pos.Worker
       ( allWorkers
       , allWorkersCount
       ) where

import           Data.Tagged             (untag)
import           Universum

import           Pos.Block.Worker        (blkWorkers)
import           Pos.Communication       (OutSpecs, WorkerSpec, localWorker, relayWorkers,
                                          wrapActionSpec)
import           Pos.Communication.Specs (allOutSpecs)
import           Pos.Delegation          (dlgWorkers)
import           Pos.DHT.Workers         (dhtWorkers)
import           Pos.Lrc.Worker          (lrcOnNewSlotWorker)
import           Pos.Security.Workers    (SecurityWorkersClass, securityWorkers)
import           Pos.Slotting.Class      (MonadSlots (slottingWorkers))
import           Pos.Slotting.Util       (logNewSlotWorker)
import           Pos.Ssc.Class.Workers   (SscWorkersClass, sscWorkers)
import           Pos.Update              (usWorkers)
import           Pos.Util                (mconcatPair)
import           Pos.Worker.SysStart     (sysStartWorker)
import           Pos.WorkMode            (WorkMode)

-- | All, but in reality not all, workers used by full node.
allWorkers
    :: (SscWorkersClass ssc, SecurityWorkersClass ssc, WorkMode ssc m)
    => ([WorkerSpec m], OutSpecs)
allWorkers = mconcatPair
    [
      -- Only workers of "onNewSlot" type

      -- TODO cannot have this DHT worker here. It assumes Kademlia.
      wrap' "dht"        $ dhtWorkers

    , wrap' "ssc"        $ untag sscWorkers
    , wrap' "security"   $ untag securityWorkers
    , wrap' "lrc"        $ first pure lrcOnNewSlotWorker
    , wrap' "us"         $ usWorkers
    , wrap' "sysStart"   $ first pure sysStartWorker

      -- Have custom loggers
    , wrap' "block"      $ blkWorkers
    , wrap' "delegation" $ dlgWorkers
    , wrap' "slotting"   $ (properSlottingWorkers, mempty)
    , wrap' "relay"      $ relayWorkers allOutSpecs

    -- I don't know, guys, I don't know :(
    -- , const ([], mempty) statsWorkers
    ]
  where
    properSlottingWorkers =
        map (fst . localWorker) (logNewSlotWorker:slottingWorkers)
    wrap' lname = first (map $ wrapActionSpec $ "worker" <> lname)

allWorkersCount
    :: forall ssc m.
       (SscWorkersClass ssc, SecurityWorkersClass ssc, WorkMode ssc m)
    => Int
allWorkersCount = length $ fst (allWorkers @ssc @m)
