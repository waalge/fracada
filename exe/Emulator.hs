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

import           Control.Monad              hiding (fmap)
import           Control.Monad.Freer.Extras as Extras
import           Data.Default               (Default (..))
import qualified Data.Map                   as Map
import           Fracada
import           Ledger.Ada                 as Ada
import           Ledger.Value               as Value
import           Plutus.Trace.Emulator      as Emulator
import           PlutusTx.Prelude
import           PlutusTx.Prelude           hiding (Semigroup (..), unless)
import           Prelude                    (IO, Show (..), show)
import           Wallet.Emulator.Wallet

nftCurrency :: CurrencySymbol
nftCurrency = "66"

nftName :: TokenName
nftName = "NFT"

nft :: AssetClass
nft = AssetClass (nftCurrency, nftName)


main :: IO ()
main = do
    runEmulatorTraceIO' def emCfg scenario1
    runEmulatorTraceIO' def emCfg scenario2

emCfg :: EmulatorConfig
emCfg = EmulatorConfig (Left $ Map.fromList [(knownWallet w, v) | w <- [1 .. 2]]) def def
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

scenario2 :: EmulatorTrace ()
scenario2 = do
    h1 <- activateContractWallet (knownWallet 1) endpoints
    h2 <- activateContractWallet (knownWallet 2) endpoints
    void $ Emulator.waitNSlots 1
    let
        toFraction = ToFraction
            { nftAsset = nft
            , fractions = 10
            , fractionTokenName = tokenName "Frac"
            }
    callEndpoint @"1-lockNFT" h1 nft
    callEndpoint @"2-fractionNFT" h1 toFraction

    void $ Emulator.waitNSlots 1

    -- callEndpoint @"3-returnNFT" h1 nft
    void $ Emulator.waitNSlots 1
