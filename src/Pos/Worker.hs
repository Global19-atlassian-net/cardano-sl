{-# LANGUAGE FlexibleContexts #-}

-- | High level workers.

module Pos.Worker
       ( runWorkers
       , statsWorkers
       ) where

import           Control.TimeWarp.Timed (fork_, forkLabeled_, ms)
import           Data.Tagged            (untag)
import           Formatting             (sformat, (%))
import           System.Wlog            (logDebug, logInfo, logNotice)
import           Universum

import           Pos.Communication      (SysStartResponse (..))
import           Pos.Constants          (slotDuration, sysTimeBroadcastSlots)
import           Pos.DHT                (sendToNetwork)
import           Pos.Slotting           (onNewSlot)
import           Pos.Ssc.Class.Workers  (SscWorkersClass, sscWorkers)
import           Pos.Types              (SlotId, flattenSlotId, slotIdF)
import           Pos.Util               (waitRandomInterval)
import           Pos.Worker.Block       (blkOnNewSlot, blocksTransmitter)
import           Pos.Worker.Stats       (statsWorkers)
import           Pos.Worker.Tx          (txsTransmitter)
import           Pos.WorkMode           (NodeContext (..), WorkMode, getNodeContext)

-- | Run all necessary workers in separate threads. This call doesn't
-- block.
runWorkers :: (SscWorkersClass ssc,  WorkMode ssc m) => m ()
runWorkers = sequence_ $ concat
    [ [forkLabeled_ "onNewSlotWorker" onNewSlotWorker]
    , [forkLabeled_ "blkTransmitter" blocksTransmitter]
    , fmap (uncurry forkLabeled_) (untag sscWorkers)
    , [forkLabeled_ "txsTransmitter" txsTransmitter]
    ]

onNewSlotWorker :: WorkMode ssc m => m ()
onNewSlotWorker = onNewSlot True onNewSlotWorkerImpl

onNewSlotWorkerImpl :: WorkMode ssc m => SlotId -> m ()
onNewSlotWorkerImpl slotId = do
    logNotice $ sformat ("New slot has just started: "%slotIdF) slotId
    -- A note about order: currently all onNewSlot updates can be run
    -- in parallel and we try to maintain this rule. If at some point
    -- order becomes important, update this comment! I don't think you
    -- will read it, but who knows…
    when (flattenSlotId slotId <= sysTimeBroadcastSlots) $
      whenM (ncTimeLord <$> getNodeContext) $ fork_ $ do
        let send = ncSystemStart <$> getNodeContext
                    >>= \sysStart -> do
                        logInfo "Broadcasting system start"
                        sendToNetwork $ SysStartResponse sysStart (Just slotId)
        send
        waitRandomInterval (ms 500) (slotDuration `div` 2)
        send

    blkOnNewSlot slotId
    logDebug "Finished `blkOnNewSlot`"
