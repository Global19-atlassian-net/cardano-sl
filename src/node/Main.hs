{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

{-# OPTIONS -fno-cross-module-specialise #-}

module Main
       ( main
       ) where

import           Universum

import           Control.Monad.Trans        (MonadTrans)
import qualified Data.ByteString.Char8      as BS8 (unpack)
import           Data.Maybe                 (fromJust)
import qualified Data.Set                   as S (fromList)
import           Data.Time.Clock.POSIX      (getPOSIXTime)
import           Data.Time.Units            (toMicroseconds)
import qualified Ether
import           Formatting                 (sformat, shown, (%))
import           Mockable                   (Production, currentTime)
import           Network.Transport.Abstract (Transport, hoistTransport)
import qualified Network.Transport.TCP      as TCP (TCPAddr (..), TCPAddrInfo (..))
import           Node                       (hoistSendActions)
import           Serokell.Util              (sec)
import           System.Wlog                (logError, logInfo)

import           Pos.Binary                 ()
import qualified Pos.CLI                    as CLI
import           Pos.Communication          (ActionSpec (..), NodeId, OutSpecs,
                                             WorkerSpec, worker, wrapActionSpec)
import           Pos.Constants              (isDevelopment)
import           Pos.Context                (MonadNodeContext, recoveryCommGuard)
import           Pos.Core.Types             (Timestamp (..))
import           Pos.DHT.Real               (KademliaDHTInstance (..),
                                             foreverRejoinNetwork)
import           Pos.DHT.Workers            (dhtWorkers)
import           Pos.Discovery              (askDHTInstance, getPeers, runDiscoveryConstT,
                                             runDiscoveryKademliaT)
import           Pos.Launcher               (NodeParams (..), bracketResources,
                                             bracketResourcesKademlia, runNode,
                                             runNodeProduction, runNodeStatic)
import           Pos.Security               (SecurityWorkersClass)
import           Pos.Shutdown               (triggerShutdown)
import           Pos.Ssc.Class              (SscConstraint, SscParams)
import           Pos.Ssc.GodTossing         (SscGodTossing)
import           Pos.Ssc.NistBeacon         (SscNistBeacon)
import           Pos.Ssc.SscAlgo            (SscAlgo (..))
import           Pos.Update.Context         (ucUpdateSemaphore)
import           Pos.Util                   (inAssertMode)
import           Pos.Util.TimeWarp          (addressToNodeId)
import           Pos.Util.UserSecret        (usVss)
import           Pos.Util.Util              (powerLift)
import           Pos.WorkMode               (ProductionMode, RawRealMode, StaticMode,
                                             WorkMode)
#ifdef WITH_WALLET
import           Pos.Wallet                 (WalletSscType)
#endif
#ifdef WITH_WEB
import           Pos.Web                    (serveWebGT)
#ifdef WITH_WALLET
import           Pos.Wallet.Web             (WalletProductionMode, WalletStaticMode,
                                             bracketWalletWS, bracketWalletWebDB,
                                             runWProductionMode, runWStaticMode,
                                             walletServeWebFull, walletServeWebFullS,
                                             walletServerOuts)
#endif
#endif

import           NodeOptions                (Args (..), getNodeOptions)
import           Params                     (getBaseParams, getKademliaParams,
                                             getNodeParams, getPeersFromArgs, gtSscParams)

action
    :: Either KademliaDHTInstance (Set NodeId)
    -> Args
    -> (forall ssc . Transport (RawRealMode ssc))
    -> Production ()
action peerHolder args@Args {..} transport = do
    systemStart <- getNodeSystemStart $ CLI.sysStart commonArgs
    logInfo $ sformat ("System start time is " % shown) systemStart
    t <- currentTime
    logInfo $ sformat ("Current time is " % shown) (Timestamp t)
    currentParams <- getNodeParams args systemStart
    putText $ "Running using " <> show (CLI.sscAlgo commonArgs)
#ifdef WITH_WALLET
    putText $ "Is wallet enabled: " <> show enableWallet
#else
    putText "Wallet is disabled, because software is built w/o it"
#endif
    putText $ "Static peers is on: " <> show staticPeers

    let vssSK = fromJust $ npUserSecret currentParams ^. usVss
    let gtParams = gtSscParams args vssSK
    let wDhtWorkers :: WorkMode ssc m => KademliaDHTInstance -> ([WorkerSpec m], OutSpecs)
        wDhtWorkers = (\(ws, outs) -> (map (fst . recoveryCommGuard . (, outs)) ws, outs)) . -- TODO simplify
                      first (map $ wrapActionSpec $ "worker" <> "dht") . dhtWorkers

#ifdef WITH_WEB
    when enableWallet $ do
        let currentPluginsGT :: (MonadNodeContext SscGodTossing m, WorkMode SscGodTossing m) => [m ()]
            currentPluginsGT = pluginsGT args
        bracketWalletWebDB walletDbPath walletRebuildDb $ \db ->
            bracketWalletWS $ \conn -> do
                let allPlugins :: (MonadNodeContext SscGodTossing m, WorkMode SscGodTossing m)
                               => KademliaDHTInstance
                               -> ([WorkerSpec m], OutSpecs)
                    allPlugins ki = mconcat [wDhtWorkers ki, convPlugins currentPluginsGT]

                case (peerHolder, CLI.sscAlgo commonArgs) of
                    (Right peers, GodTossingAlgo) ->
                        runWStaticMode db conn
                            peers transportW
                            currentParams gtParams
                            (runNode @SscGodTossing $ (convPlugins currentPluginsGT) <> walletStatic args)
                    (Left kad, GodTossingAlgo) ->
                        runWProductionMode db conn
                            kad transportW
                            currentParams gtParams
                            (runNode @SscGodTossing (allPlugins kad <> walletProd args))
                    (_, NistBeaconAlgo) ->
                        logError "Wallet does not support NIST beacon!"
#endif
#ifdef WITH_WALLET
    let userWantsWallet = enableWallet
#else
    let userWantsWallet = False
#endif
    unless userWantsWallet $ do
        let sscParams :: Either (SscParams SscNistBeacon) (SscParams SscGodTossing)
            sscParams = bool (Left ()) (Right gtParams) (CLI.sscAlgo commonArgs == GodTossingAlgo)

        case peerHolder of
            Right peers -> do
                let runner :: forall ssc .
                        (SscConstraint ssc, SecurityWorkersClass ssc)
                        => SscParams ssc -> Production ()
                    runner =
                        runNodeStatic @ssc
                            peers
                            transportR
                            utwStatic
                            currentParams
                either (runner @SscNistBeacon) (runner @SscGodTossing) sscParams
            Left kad -> do
                let runner :: forall ssc .
                        (SscConstraint ssc, SecurityWorkersClass ssc)
                        => SscParams ssc -> Production ()
                    runner =
                        runNodeProduction @ssc
                            kad
                            transportR
                            (mconcat [wDhtWorkers kad, utwProd])
                            currentParams
                either (runner @SscNistBeacon) (runner @SscGodTossing) sscParams
  where
    transportR ::
        forall ssc t0 .
        ( MonadTrans t0
        , Monad (t0 (RawRealMode ssc))
        )
        => Transport (t0 (RawRealMode ssc))
    transportR = hoistTransport lift transport

#ifdef WITH_WEB
    convPlugins = (,mempty) . map (\act -> ActionSpec $ \__vI __sA -> act)

    transportW ::
        forall ssc t0 t1 t2 .
        ( Each '[MonadTrans] [t0, t1, t2]
        , Each '[Monad] [ t0 (RawRealMode ssc)
                        , t1 (t0 (RawRealMode ssc))
                        , t2 (t1 (t0 (RawRealMode ssc)))
                        ]
        )
        => Transport (t2 $ t1 $ t0 (RawRealMode ssc))
    transportW = hoistTransport (lift . lift . lift) transport
#endif

#ifdef WITH_WEB
pluginsGT ::
    ( WorkMode SscGodTossing m
    , MonadNodeContext SscGodTossing m
    ) => Args -> [m ()]
pluginsGT Args {..}
    | enableWeb = [serveWebGT webPort]
    | otherwise = []
#endif

utwProd :: SscConstraint ssc => ([WorkerSpec (ProductionMode ssc)], OutSpecs)
utwProd = first (map liftPlugin) updateTriggerWorker
  where
    liftPlugin (ActionSpec p) = ActionSpec $ \vI sa -> do
        ki <- askDHTInstance
        lift . p vI $ hoistSendActions (runDiscoveryKademliaT ki) lift sa

utwStatic :: SscConstraint ssc => ([WorkerSpec (StaticMode ssc)], OutSpecs)
utwStatic = first (map liftPlugin) updateTriggerWorker
  where
    liftPlugin (ActionSpec p) = ActionSpec $ \vI sa -> do
        peers <- getPeers
        lift . p vI $ hoistSendActions (runDiscoveryConstT peers) lift sa

updateTriggerWorker
    :: SscConstraint ssc
    => ([WorkerSpec (RawRealMode ssc)], OutSpecs)
updateTriggerWorker = first pure $ worker mempty $ \_ -> do
    logInfo "Update trigger worker is locked"
    void $ takeMVar =<< Ether.asks' ucUpdateSemaphore
    triggerShutdown

----------------------------------------------------------------------------
-- Wallet stuff
----------------------------------------------------------------------------

#ifdef WITH_WALLET

walletProd
    :: SscConstraint WalletSscType
    => Args
    -> ([WorkerSpec WalletProductionMode], OutSpecs)
walletProd Args {..} = first pure $ worker walletServerOuts $ \sendActions ->
    walletServeWebFull
        sendActions
        walletDebug
        walletPort

walletStatic
    :: SscConstraint WalletSscType
    => Args
    -> ([WorkerSpec WalletStaticMode], OutSpecs)
walletStatic Args{..} =  first pure $ worker walletServerOuts $ \sendActions ->
    walletServeWebFullS
        sendActions
        walletDebug
        walletPort

#endif

printFlags :: IO ()
printFlags = do
    if isDevelopment
        then putText "[Attention] We are in DEV mode"
        else putText "[Attention] We are in PRODUCTION mode"
#ifdef WITH_WEB
    putText "[Attention] Web-mode is on"
#endif
#ifdef WITH_WALLET
    putText "[Attention] Wallet-mode is on"
#endif
    inAssertMode $ putText "Asserts are ON"


getNodeSystemStart :: MonadIO m => Timestamp -> m Timestamp
getNodeSystemStart cliOrConfigSystemStart
  | cliOrConfigSystemStart >= 1400000000 =
    -- UNIX time 1400000000 is Tue, 13 May 2014 16:53:20 GMT.
    -- It was chosen arbitrarily as some date far enough in the past.
    -- See CSL-983 for more information.
    pure cliOrConfigSystemStart
  | otherwise = do
    let frameLength = timestampToSeconds cliOrConfigSystemStart
    currentPOSIXTime <- liftIO $ round <$> getPOSIXTime
    -- The whole timeline is split into frames, with the first frame starting
    -- at UNIX epoch start. We're looking for a time `t` which would be in the
    -- middle of the same frame as the current UNIX time.
    let currentFrame = currentPOSIXTime `div` frameLength
        t = currentFrame * frameLength + (frameLength `div` 2)
    pure $ Timestamp $ sec $ fromIntegral t
  where
    timestampToSeconds :: Timestamp -> Integer
    timestampToSeconds = (`div` 1000000) . toMicroseconds . getTimestamp

main :: IO ()
main = do
    args <- getNodeOptions
    printFlags
    let baseParams = getBaseParams "node" args
    if staticPeers args then do
        allPeers <- S.fromList . map addressToNodeId <$> getPeersFromArgs args
        bracketResources baseParams TCP.Unaddressable $ \transport -> do
            let transport' = hoistTransport
                    (powerLift :: forall ssc t . Production t -> RawRealMode ssc t)
                    transport
            action (Right allPeers) args transport'
    else do
        let (bindHost, bindPort) = bindAddress args
        let (externalHost, externalPort) = externalAddress args
        let tcpAddr = TCP.Addressable $
                TCP.TCPAddrInfo (BS8.unpack bindHost) (show $ bindPort)
                                (const (BS8.unpack externalHost, show $ externalPort))
        kademliaParams <- liftIO $ getKademliaParams args
        bracketResourcesKademlia baseParams tcpAddr kademliaParams $ \kademliaInstance transport ->
            let transport' = hoistTransport
                    (powerLift :: forall ssc t . Production t -> RawRealMode ssc t)
                    transport
            in  foreverRejoinNetwork kademliaInstance (action (Left kademliaInstance) args transport')
