module Daedalus.Types
       ( module CT
       , module C
       , module E
       , module BP
       , module DT
       , _address
       , _ccoin
       , _passPhrase
       , mkCCoin
       , mkCId
       , mkCAccountMeta
       , mkCAccountInit
       , mkCAccountId
       , mkCTxMeta
       , mkCTxId
       , mkCProfile
       , _ctxIdValue
       , mkBackupPhrase
       , mkCWalletRedeem
       , mkCPaperVendWalletRedeem
       , mkCInitialized
       , mkCPassPhrase
       , emptyCPassPhrase
       , getProfileLocale
       , walletAddressToUrl
       , mkCWalletInit
       , mkCWalletAssurance
       ) where

import Prelude

import Pos.Wallet.Web.ClientTypes (CId (..), CHash (..), CPassPhrase (..), CCoin (..), Wal (..), CAccountId (..), CWalletMeta (..))

import Pos.Wallet.Web.ClientTypes as CT
import Pos.Core.Types as C
import Pos.Wallet.Web.Error.Types as E
import Pos.Util.BackupPhrase (BackupPhrase (..))
import Pos.Util.BackupPhrase as BP

import Control.Monad.Eff.Exception (error, Error)
import Data.Either (either, Either (..))
import Data.Maybe (Maybe (..))
import Data.Argonaut.Generic.Aeson (decodeJson)
import Data.Argonaut.Core (fromString)
import Data.Generic (gShow)
import Data.Array.Partial (last)
import Data.Array (length, filter)
import Partial.Unsafe (unsafePartial)
import Data.String (split, null, trim, joinWith, Pattern (..))

import Daedalus.Crypto (isValidMnemonic, blake2b, bytesToB16)
import Data.Types (mkTime)
import Data.Types as DT
import Data.Int53 (fromInt, toString)

space :: Pattern
space = Pattern " "

dot :: Pattern
dot = Pattern "."

backupMnemonicLen :: Int
backupMnemonicLen = 12

paperVendMnemonicLen :: Int
paperVendMnemonicLen = 9

-- NOTE: if you will be bumping bip39 to >=2.2.0 be aware of https://issues.serokell.io/issue/VD-95 . In this case you will have to modify how we validate paperVendMnemonics.
mkBackupPhrase :: Int -> String -> Either Error BackupPhrase
mkBackupPhrase len mnemonic = mkBackupPhraseIgnoreChecksum len mnemonic >>= const do
    if not $ isValidMnemonic mnemonicCleaned
        then Left $ error "Invalid mnemonic: checksum missmatch"
        else Right $ BackupPhrase { bpToList: split space mnemonicCleaned }
  where
    mnemonicCleaned = cleanMnemonic mnemonic

cleanMnemonic :: String -> String
cleanMnemonic = joinWith " " <<< filter (not <<< null) <<< split space <<< trim

mkBackupPhraseIgnoreChecksum :: Int -> String -> Either Error BackupPhrase
mkBackupPhraseIgnoreChecksum len mnemonic =
    if not $ hasExactlyNwords len mnemonicCleaned
        then Left $ error $ "Invalid mnemonic: mnemonic should have exactly " <> show len <> " words"
        else Right $ BackupPhrase { bpToList: split space mnemonicCleaned }
  where
    hasExactlyNwords len' = (==) len' <<< length <<< split space
    mnemonicCleaned = cleanMnemonic mnemonic

-- TODO: it would be useful to extend purescript-bridge
-- and generate lenses
walletAddressToUrl :: CAccountId -> String
walletAddressToUrl (CAccountId r) = r

_hash :: CHash -> String
_hash (CHash h) = h

_address :: forall a. CId a -> String
_address (CId a) = _hash a

_passPhrase :: CPassPhrase -> String
_passPhrase (CPassPhrase p) = p

emptyCPassPhrase :: CPassPhrase
emptyCPassPhrase = CPassPhrase ""

mkCPassPhrase :: String -> Maybe CPassPhrase
mkCPassPhrase "" = Nothing
mkCPassPhrase pass = Just <<< CPassPhrase <<< bytesToB16 $ blake2b pass

mkCId :: forall a. String -> CId a
mkCId = CId <<< CHash

_ccoin :: CCoin -> String
_ccoin (CCoin c) = c.getCCoin

mkCCoin :: String -> CCoin
mkCCoin amount = CCoin { getCCoin: amount }

-- NOTE: use genericRead maybe https://github.com/paluh/purescript-generic-read-example
mkCWSetAssurance :: String -> CT.CWalletAssurance
mkCWSetAssurance = either (const CT.CWANormal) id <<< decodeJson <<< fromString

mkCAccountMeta :: String -> CT.CAccountMeta
mkCAccountMeta wName =
    CT.CAccountMeta { caName: wName
                   }

mkCAccountId :: String -> CT.CAccountId
mkCAccountId = CAccountId

mkCInitialized :: Int -> Int -> CT.CInitialized
mkCInitialized total preInit =
    CT.CInitialized { cTotalTime: fromInt total
                    , cPreInit: fromInt preInit
                    }

mkCAccountInit :: String -> CId Wal -> CT.CAccountInit
mkCAccountInit wName wSetId =
    CT.CAccountInit { cwInitWId: wSetId
                   , caInitMeta: mkCAccountMeta wName
                   }

mkCWalletAssurance :: String -> CT.CWalletAssurance
mkCWalletAssurance = either (const CT.CWANormal) id <<< decodeJson <<< fromString

mkCWalletInit :: String -> String -> Int -> String -> Either Error CT.CWalletInit
mkCWalletInit wSetName wsAssurance wsUnit mnemonic = do
    bp <- mkBackupPhrase backupMnemonicLen mnemonic
    pure $ CT.CWalletInit { cwInitMeta:
                                CWalletMeta
                                    { cwName: wSetName
                                    , cwAssurance: mkCWalletAssurance wsAssurance
                                    , csUnit: wsUnit
                                    }
                             , cwBackupPhrase: bp
                             }


mkCWalletRedeem :: String -> CAccountId -> CT.CWalletRedeem
mkCWalletRedeem seed wAddress = do
    CT.CWalletRedeem { crWalletId: wAddress
                     , crSeed: seed
                     }

-- NOTE: if you will be bumping bip39 to >=2.2.0 be aware of https://issues.serokell.io/issue/VD-95 . In this case you will have to modify how we validate paperVendMnemonics.
mkCPaperVendWalletRedeem :: String -> String -> CAccountId -> Either Error CT.CPaperVendWalletRedeem
mkCPaperVendWalletRedeem seed mnemonic wAddress = do
    bp <- mkBackupPhrase paperVendMnemonicLen mnemonic
    pure $ CT.CPaperVendWalletRedeem { pvWalletId: wAddress
                                     , pvBackupPhrase: bp
                                     , pvSeed: seed
                                     }

_ctxIdValue :: CT.CTxId -> String
_ctxIdValue (CT.CTxId tx) = _hash tx

mkCTxId :: String -> CT.CTxId
mkCTxId = CT.CTxId <<< CHash

mkCTxMeta :: String -> String -> Number -> CT.CTxMeta
mkCTxMeta title description date =
    CT.CTxMeta { ctmTitle: title
               , ctmDescription: description
               , ctmDate: mkTime date
               }

mkCProfile :: String -> CT.CProfile
mkCProfile locale =
    CT.CProfile { cpLocale: locale
                }

getProfileLocale :: CT.CProfile -> String
getProfileLocale (CT.CProfile r) = r.cpLocale
