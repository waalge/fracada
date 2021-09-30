{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

import           Prelude                    (IO, Show (..), show)
-- import           Control.Monad          hiding (fmap)
import           Ledger.Value               as Value
import           Plutus.Trace.Emulator      as Emulator
import           PlutusTx.Prelude           hiding (Semigroup (..), unless)
import           Wallet.Emulator.Wallet
-- import           Control.Monad.Freer.Extras as Extras
import           Fracada
-- import           Plutus.Contract        as Contract
import qualified Data.Map                   as Map
import           Ledger.Ada                 as Ada
-- import           Control.Lens
import           Control.Monad              hiding (fmap)
import           Control.Monad.Freer.Extras as Extras
import           Data.Default               (Default (..))
-- import qualified Data.Map                   as Map
-- import           Data.Monoid                (Last (..))
-- import           Ledger
-- import           Ledger.Value
-- import           Ledger.Ada                 as Ada
-- import           Plutus.Contract.Test
-- import           Plutus.Trace.Emulator      as Emulator
import           PlutusTx.Prelude
-- import           Test.Tasty

nftCurrency :: CurrencySymbol
nftCurrency = "66"

nftName :: TokenName
nftName = "NFT"

nft :: AssetClass
nft = AssetClass (nftCurrency, nftName)


main :: IO ()
main = runEmulatorTraceIO' def emCfg scenario1

emCfg :: EmulatorConfig
emCfg = EmulatorConfig (Left $ Map.fromList [(knownWallet w, v) | w <- [1 .. 1]]) def def
    where
        v = Ada.lovelaceValueOf 1000_000_000 <> assetClassValue nft 1

scenario1 :: EmulatorTrace ()
scenario1 = do
    h1 <- activateContractWallet (knownWallet 1) endpoints
    void $ Emulator.waitNSlots 1
    let
        toFraction = ToFraction
            { nftAsset = nft
            , fractions = 10
            , fractionTokenName = tokenName "Frac"
            }
    callEndpoint @"1-lockNFT" h1 nft
    void $ Emulator.waitNSlots 1
    callEndpoint @"2-fractionNFT" h1 toFraction
    void $ Emulator.waitNSlots 1

    callEndpoint @"3-returnNFT" h1 nft
    void $ Emulator.waitNSlots 1
