{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeOperators       #-}

module Main
  ( main
  ) where

import           Control.Lens                       (mapped, (?~))
import           Data.Aeson                         (encode)
import qualified Data.ByteString.Lazy.Char8         as BSL8
import           Data.Swagger                       (NamedSchema (..), Operation, Swagger,
                                                     SwaggerType (..), ToParamSchema (..),
                                                     ToSchema (..), declareNamedSchema,
                                                     declareSchemaRef,
                                                     defaultSchemaOptions, description,
                                                     format, genericDeclareNamedSchema,
                                                     host, info, name, properties,
                                                     required, title, type_, version)
import           Data.Typeable                      (Typeable, typeRep)
import           Data.Version                       (showVersion)
import           Options.Applicative.Simple         (execParser, footer, fullDesc, header,
                                                     help, helper, infoOption, long,
                                                     progDesc)
import qualified Options.Applicative.Simple         as S
import           Servant                            ((:>))
import           Servant.Multipart                  (FileData (..), MultipartForm)
import           Servant.Swagger                    (HasSwagger (toSwagger),
                                                     subOperations)
import           Servant.Swagger.Internal.TypeLevel (IsSubAPI)
import           Universum

import qualified Paths_cardano_sl                   as CSL
import           Pos.Types                          (ApplicationName, BlockVersion,
                                                     ChainDifficulty, Coin,
                                                     SoftwareVersion)
import           Pos.Util.BackupPhrase              (BackupPhrase)
import           Pos.Util.Servant                   (CDecodeApiArg, VerbMod,
                                                     WithDefaultApiArg)
import qualified Pos.Wallet.Web                     as W

import qualified Description                        as D

showProgramInfoIfRequired :: FilePath -> IO ()
showProgramInfoIfRequired generatedJSON = void $ execParser programInfo
  where
    programInfo = S.info (helper <*> versionOption) $
        fullDesc <> progDesc "Generate Swagger specification for Wallet web API."
                 <> header   "Cardano SL Wallet web API docs generator."
                 <> footer   ("This program runs during 'cardano-sl' building on Travis CI. " <>
                              "Generated file '" <> generatedJSON <> "' will be used to produce HTML documentation. " <>
                              "This documentation will be published at cardanodocs.com using 'update_wallet_web_api_docs.sh'.")

    versionOption = infoOption
        ("cardano-swagger-" <> showVersion CSL.version)
        (long "version" <> help "Show version.")


main :: IO ()
main = do
    showProgramInfoIfRequired jsonFile
    BSL8.writeFile jsonFile $ encode swaggerSpecForWalletApi
    putStrLn $ "Done. See " <> jsonFile <> "."
  where
    jsonFile = "wallet-web-api-swagger.json"

instance HasSwagger api => HasSwagger (MultipartForm a :> api) where
    toSwagger Proxy = toSwagger $ Proxy @api

instance ToSchema FileData where
    declareNamedSchema _ = do
        textSchema <- declareSchemaRef (Proxy :: Proxy Text)
        filepathSchema <- declareSchemaRef (Proxy :: Proxy FilePath)
        return $ NamedSchema (Just "FileData") $ mempty
            & type_ .~ SwaggerObject
            & properties .~
                [ ("fdInputFile", textSchema)
                , ("fdFileName", textSchema)
                , ("fdFileCType", textSchema)
                , ("fdFilePath", filepathSchema)
                ]
            & required .~ [ "fdInputFile", "fdFileName", "fdFileCType", "fdFilePath"]

-- | Instances we need to build Swagger-specification for 'walletApi':
-- 'ToParamSchema' - for types in parameters ('Capture', etc.),
-- 'ToSchema' - for types in bodies.
instance ToSchema      Coin
instance ToParamSchema Coin
instance ToSchema      W.CTxId
instance ToParamSchema W.CTxId
instance ToSchema      W.CTx
instance ToSchema      W.CTxMeta
instance ToSchema      W.CHash
instance ToParamSchema W.CHash
instance ToSchema      (W.CId W.Wal)
instance ToSchema      (W.CId W.Addr)
instance ToParamSchema (W.CId W.Wal)
instance ToParamSchema (W.CId W.Addr)
instance ToSchema      W.CProfile
instance ToSchema      W.WalletError

-- TODO: currently not used
instance ToSchema      W.CWAddressMeta
instance ToParamSchema W.CWAddressMeta where
    toParamSchema _ = mempty
        & type_ .~ SwaggerString
        & format ?~ "walletSetAddress@walletIndex@accountIndex@address"

instance ToSchema      W.CAccountId
instance ToParamSchema W.CAccountId where
    toParamSchema _ = mempty
        & type_ .~ SwaggerString
        & format ?~ "walletSetAddress@walletKeyIndex"

instance ToSchema      W.CWalletAssurance
instance ToSchema      W.CAccountMeta
instance ToSchema      W.CWalletMeta
instance ToSchema      W.CAccountInit
instance ToSchema      W.CWalletInit
instance ToSchema      W.CWalletRedeem
instance ToSchema      W.CWallet
instance ToSchema      W.CAccount
instance ToSchema      W.CAddress
instance ToSchema      W.CPaperVendWalletRedeem
instance ToSchema      W.CCoin
instance ToSchema      W.CInitialized
instance ToSchema      W.CElectronCrashReport
instance ToSchema      W.CUpdateInfo
instance ToSchema      SoftwareVersion
instance ToSchema      ApplicationName
instance ToSchema      W.SyncProgress
instance ToSchema      ChainDifficulty
instance ToSchema      BlockVersion
instance ToSchema      BackupPhrase
instance ToParamSchema W.CPassPhrase

-- | Instance for Either-based types (types we return as 'Right') in responses.
-- Due 'typeOf' these types must be 'Typeable'.
-- We need this instance for correct Swagger-specification.
instance {-# OVERLAPPING #-} (Typeable a, ToSchema a) => ToSchema (Either W.WalletError a) where
    declareNamedSchema proxy = genericDeclareNamedSchema defaultSchemaOptions proxy
        & mapped . name ?~ show (typeRep (Proxy @(Either W.WalletError a)))

instance HasSwagger v =>
         HasSwagger (VerbMod mod v) where
    toSwagger _ = toSwagger (Proxy @v)

instance HasSwagger (apiType a :> res) =>
         HasSwagger (CDecodeApiArg apiType a :> res) where
    toSwagger _ = toSwagger (Proxy @(apiType a :> res))

instance HasSwagger (apiType a :> res) =>
         HasSwagger (WithDefaultApiArg apiType a :> res) where
    toSwagger _ = toSwagger (Proxy @(apiType a :> res))

-- | Wallet API operations.
walletOp
    :: forall sub.
       ( IsSubAPI (W.ApiPrefix :> sub) W.WalletApi
       , HasSwagger (W.ApiPrefix :> sub)
       )
    => Traversal' Swagger Operation
walletOp = subOperations (Proxy @(W.ApiPrefix :> sub)) W.walletApi

-- | Build Swagger-specification from 'walletApi'.
swaggerSpecForWalletApi :: Swagger
swaggerSpecForWalletApi = toSwagger W.walletApi
    & info . title       .~ "Cardano SL Wallet Web API"
    & info . version     .~ (toText $ showVersion CSL.version)
    & info . description ?~ "This is an API for Cardano SL wallet."
    & host               ?~ "localhost:8090" -- Default node's port for wallet web API.
    -- Descriptions for all endpoints.
    & testReset              . description ?~ D.testResetDescription

    & getWSet                . description ?~ D.getWSetDescription
    & getWSets               . description ?~ D.getWSetsDescription
    & newWSet                . description ?~ D.newWSetDescription
    & restoreWSet            . description ?~ D.restoreWSetDescription
    & renameWSet             . description ?~ D.renameWSetDescription
    & deleteWSet             . description ?~ D.deleteWSetDescription
    & importWSet             . description ?~ D.importWSetDescription
    & changeWSetPassphrase   . description ?~ D.changeWSetPassphraseDescription

    & getWallet              . description ?~ D.getWalletDescription
    & getWallets             . description ?~ D.getWalletsDescription
    & updateWallet           . description ?~ D.updateWalletDescription
    & newWallet              . description ?~ D.newWalletDescription
    & deleteWallet           . description ?~ D.deleteWalletDescription

    & newAccount             . description ?~ D.newAccountDescription

    & isValidAddress         . description ?~ D.isValidAddressDescription

    & getProfile             . description ?~ D.getProfileDescription
    & updateProfile          . description ?~ D.updateProfileDescription

    & newPayment             . description ?~ D.newPaymentDescription
    & newPaymentExt          . description ?~ D.newPaymentExtDescription
    & updateTx               . description ?~ D.updateTxDescription
    & getHistory             . description ?~ D.getHistoryDescription
    & searchHistory          . description ?~ D.searchHistoryDescription

    & nextUpdate             . description ?~ D.nextUpdateDescription
    & applyUpdate            . description ?~ D.applyUpdateDescription

    & redeemADA              . description ?~ D.redeemADADescription
    & redeemADAPaperVend     . description ?~ D.redeemADAPaperVendDescription

    & reportingInitialized   . description ?~ D.reportingInitializedDescription
    & reportingElectroncrash . description ?~ D.reportingElectroncrashDescription

    & getSlotsDuration       . description ?~ D.getSlotsDurationDescription
    & getVersion             . description ?~ D.getVersionDescription
    & getSyncProgress        . description ?~ D.getSyncProgressDescription
  where
    -- | SubOperations for all endpoints in 'walletApi'.
    -- We need it to fill description sections in produced HTML-documentation.
    testReset              = walletOp @W.TestReset

    getWSet                = walletOp @W.GetWalletSet
    getWSets               = walletOp @W.GetWalletSets
    newWSet                = walletOp @W.NewWalletSet
    restoreWSet            = walletOp @W.RestoreWalletSet
    renameWSet             = walletOp @W.RenameWalletSet
    deleteWSet             = walletOp @W.DeleteWalletSet
    importWSet             = walletOp @W.ImportWalletSet
    changeWSetPassphrase   = walletOp @W.ChangeWalletSetPassphrase

    getWallet              = walletOp @W.GetWallet
    getWallets             = walletOp @W.GetWallets
    updateWallet           = walletOp @W.UpdateWallet
    newWallet              = walletOp @W.NewWallet
    deleteWallet           = walletOp @W.DeleteWallet

    newAccount             = walletOp @W.NewAccount

    isValidAddress         = walletOp @W.IsValidAddress

    getProfile             = walletOp @W.GetProfile
    updateProfile          = walletOp @W.UpdateProfile

    newPayment             = walletOp @W.NewPayment
    newPaymentExt          = walletOp @W.NewPaymentExt
    updateTx               = walletOp @W.UpdateTx
    getHistory             = walletOp @W.GetHistory
    searchHistory          = walletOp @W.SearchHistory

    nextUpdate             = walletOp @W.NextUpdate
    applyUpdate            = walletOp @W.ApplyUpdate

    redeemADA              = walletOp @W.RedeemADA
    redeemADAPaperVend     = walletOp @W.RedeemADAPaperVend

    reportingInitialized   = walletOp @W.ReportingInitialized
    reportingElectroncrash = walletOp @W.ReportingElectroncrash

    getSlotsDuration       = walletOp @W.GetSlotsDuration
    getVersion             = walletOp @W.GetVersion
    getSyncProgress        = walletOp @W.GetSyncProgress
