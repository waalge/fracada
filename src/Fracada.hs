{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}


module Fracada where

import           Control.Monad          hiding (fmap)
import           Data.Aeson             (FromJSON, ToJSON)
import qualified Data.Map               as Map
import           Data.Maybe             (fromJust)
import           Data.Text              (Text)
import           Data.Void              (Void)
import           GHC.Generics           (Generic)
import           Ledger                 hiding (singleton)
import           Ledger.Constraints     as Constraints
import qualified Ledger.Contexts        as Validation
import qualified Ledger.Typed.Scripts   as Scripts
import           Ledger.Value           as Value
import           Playground.Contract    (NonEmpty (..), ToSchema,
                                         ensureKnownCurrencies, printJson,
                                         printSchemas, stage)
import           Playground.TH          (ensureKnownCurrencies,
                                         mkKnownCurrencies, mkSchemaDefinitions)
import           Playground.Types       (KnownCurrency (..))
import           Plutus.Contract        as Contract
import           Plutus.Trace.Emulator  as Emulator
import qualified PlutusTx
import           PlutusTx.IsData
import           PlutusTx.Prelude       hiding (Semigroup (..), unless)
import           Prelude                (IO, Semigroup (..), Show, String, show)
import           Text.Printf            (printf)
import           Wallet.Emulator.Wallet


data FractionNFTDatum = FractionNFTDatum {
      tokensClass    :: AssetClass,
      totalFractions :: Integer,
      owner          :: PubKeyHash
    } deriving (Generic, Show)

PlutusTx.makeLift ''FractionNFTDatum
PlutusTx.makeIsDataIndexed ''FractionNFTDatum [('FractionNFTDatum,0)]

-- | Datum and redeemer parameter types for fractioning script
data Fractioning
instance Scripts.ValidatorTypes Fractioning where
    type instance RedeemerType Fractioning = ()
    type instance DatumType Fractioning = FractionNFTDatum

{-# INLINABLE datumToData #-}
datumToData :: (FromData a) => Datum -> Maybe a
datumToData datum = fromBuiltinData (getDatum datum)

{-# INLINABLE fractionNftValidator #-}
fractionNftValidator :: AssetClass -> FractionNFTDatum -> () -> ScriptContext -> Bool
fractionNftValidator nftAsset FractionNFTDatum{tokensClass, totalFractions, owner} _ ctx =
    let
      txInfo = scriptContextTxInfo ctx
      -- extract signer of this transaction, assume is only one
      [sig] = txInfoSignatories txInfo
      mintedTokens = assetClassValueOf (txInfoMint txInfo) tokensClass
      nftIsLocked = assetClassValueOf ( Validation.valueLockedBy txInfo (Validation.ownHash ctx)) nftAsset == 1
  in
    if (nftIsLocked) then
      let
        (_, ownDatumHash) = ownHashes ctx
        [(_,newDatum)] =  filter (\(h,d) -> h /= ownDatumHash) $ txInfoData txInfo
        Just FractionNFTDatum{totalFractions=newTotalFractions} = datumToData newDatum

        tokensMinted = mintedTokens == totalFractions
      in
      -- check fractions input  = 0 output = n
      -- owner is same
      -- tokens minted
      traceIfFalse "NFT already fractioned" (totalFractions == 0) &&
      traceIfFalse "NFT not fractioned" (newTotalFractions > 0) &&
      traceIfFalse "Tokens not minted" tokensMinted &&
      traceIfFalse "Owner not the same" (owner == sig)
    else
      let
        tokensBurnt = mintedTokens == negate totalFractions && mintedTokens /= 0
        nftIsPaidToSigner = assetClassValueOf (Validation.valuePaidTo txInfo sig ) nftAsset == 1
      in
        traceIfFalse "NFT not paid to signer" nftIsPaidToSigner &&
        traceIfFalse "Tokens not burn" tokensBurnt


fractionNftValidatorInstance ::  AssetClass -> Scripts.TypedValidator Fractioning
fractionNftValidatorInstance asset = Scripts.mkTypedValidator @Fractioning
    ($$(PlutusTx.compile [||  fractionNftValidator ||])
    `PlutusTx.applyCode`
    PlutusTx.liftCode asset)
    $$(PlutusTx.compile [|| wrap ||]) where
        wrap = Scripts.wrapValidator @FractionNFTDatum @()

fractionNftValidatorHash :: AssetClass -> ValidatorHash
fractionNftValidatorHash = Scripts.validatorHash . fractionNftValidatorInstance

fractionValidatorScript :: AssetClass -> Validator
fractionValidatorScript = Scripts.validatorScript . fractionNftValidatorInstance

fractionNftValidatorAddress :: AssetClass -> Address
fractionNftValidatorAddress = Ledger.scriptAddress . fractionValidatorScript


{-# INLINABLE mintFractionTokens #-}
mintFractionTokens :: ValidatorHash -> AssetClass -> Integer -> TokenName -> () -> ScriptContext -> Bool
mintFractionTokens fractionNFTScript asset@( AssetClass (nftCurrency, nftToken)) numberOfFractions fractionTokenName _ ctx =
  let
    info = scriptContextTxInfo ctx
    mintedAmount = case flattenValue (txInfoMint info) of
        [(cs, fractionTokenName', amt)] | cs == ownCurrencySymbol ctx && fractionTokenName' == fractionTokenName -> amt
        _                                                           -> 0
  in
    if mintedAmount > 0 then
      let
        nftValue = valueOf (valueSpent info) nftCurrency nftToken
        assetIsLocked = nftValue == 1
        lockedByNFTfractionScript = valueLockedBy info fractionNFTScript
        assetIsPaid = assetClassValueOf lockedByNFTfractionScript asset == 1
      in
        traceIfFalse "NFT not paid" assetIsPaid              &&
        traceIfFalse "NFT not locked already" assetIsLocked  &&
        traceIfFalse "wrong fraction tokens minted" ( mintedAmount == numberOfFractions)
    else
      let
        -- extract signer of this transaction, assume is only one
        [sig] = txInfoSignatories info
        assetIsReturned = assetClassValueOf (Validation.valuePaidTo info sig ) asset == 1
      in
        traceIfFalse "Asset not returned" assetIsReturned           &&
        traceIfFalse "wrong fraction tokens burned" ( mintedAmount == negate numberOfFractions)


mintFractionTokensPolicy :: AssetClass -> Integer -> TokenName -> Scripts.MintingPolicy
mintFractionTokensPolicy asset numberOfFractions fractionTokenName = mkMintingPolicyScript $
    $$(PlutusTx.compile [|| \validator' asset' numberOfFractions' fractionTokenName' -> Scripts.wrapMintingPolicy $ mintFractionTokens validator' asset' numberOfFractions' fractionTokenName' ||])
    `PlutusTx.applyCode`
    PlutusTx.liftCode ( fractionNftValidatorHash asset)
    `PlutusTx.applyCode`
    PlutusTx.liftCode asset
    `PlutusTx.applyCode`
    PlutusTx.liftCode numberOfFractions
    `PlutusTx.applyCode`
    PlutusTx.liftCode fractionTokenName

curSymbol ::  AssetClass -> Integer -> TokenName -> CurrencySymbol
curSymbol asset numberOfFractions fractionTokenName = scriptCurrencySymbol $ mintFractionTokensPolicy asset numberOfFractions fractionTokenName

data ToFraction = ToFraction
    { nftAsset          :: !AssetClass
    , fractions         :: !Integer
    , fractionTokenName :: !TokenName
    } deriving (Generic, ToJSON, FromJSON, ToSchema)

type FracNFTSchema =
    Endpoint "1-lockNFT" AssetClass
    .\/ Endpoint "2-fractionNFT" ToFraction
    .\/ Endpoint "3-returnNFT" AssetClass


extractData :: (PlutusTx.FromData a) => ChainIndexTxOut -> Maybe a
extractData ci = do
  case ci of
    ScriptChainIndexTxOut _addr _validator (Right datum) _value -> datumToData datum
    _ -> Nothing

lockNFT :: AssetClass -> Contract w FracNFTSchema Text ()
lockNFT nftAsset = do
  -- pay nft to contract
    pk    <- Contract.ownPubKey
    let
      -- keep the nft and asset class in the datum,
      -- we signal no fractioning yet with a 0 in the total fractions field
      datum =FractionNFTDatum{ tokensClass= nftAsset, totalFractions = 0, owner = pubKeyHash pk}

      -- lock the nft and the datum into the fractioning contract
      validator = fractionNftValidatorInstance nftAsset
      tx      = Constraints.mustPayToTheScript datum  $  assetClassValue nftAsset 1
    ledgerTx <- submitTxConstraints validator tx
    void $ awaitTxConfirmed $ txId ledgerTx
    Contract.logInfo @String $ printf "NFT locked"

fractionNFT :: ToFraction -> Contract w FracNFTSchema Text ()
fractionNFT ToFraction {nftAsset, fractions, fractionTokenName} = do
  -- pay nft to contract
  -- pay minted tokens back to signer
    pkh    <- pubKeyHash <$> Contract.ownPubKey
    utxos  <- utxosAt $ fractionNftValidatorAddress nftAsset
    let
      -- declare the NFT value
      nftValue = assetClassValue nftAsset 1
      -- find the UTxO that has the NFT we're looking for
      utxo@(oref, _) = fromJust ( find (\(_,v) -> nftValue == txOutValue (toTxOut v)) $ Map.toList utxos )


      --find the minting script instance
      mintingScript = mintFractionTokensPolicy nftAsset fractions fractionTokenName

      -- define the value to mint (amount of tokens) and be paid to signer
      currency = scriptCurrencySymbol mintingScript
      tokensToMint =  Value.singleton currency fractionTokenName fractions
      payBackTokens = mustPayToPubKey pkh tokensToMint

      -- value of NFT
      valueToScript = assetClassValue nftAsset 1
      -- keep the minted amount and asset class in the datum
      datum = Datum $ toBuiltinData FractionNFTDatum{ tokensClass= assetClass currency fractionTokenName, totalFractions = fractions, owner = pkh}

      --build the constraints and submit the transaction
      validator = fractionValidatorScript nftAsset

      lookups = Constraints.mintingPolicy mintingScript  <>
                Constraints.otherScript validator <>
                Constraints.unspentOutputs ( Map.fromList [utxo] )
      tx      = Constraints.mustMintValue tokensToMint <>
                Constraints.mustPayToOtherScript (fractionNftValidatorHash nftAsset) datum valueToScript <>
                Constraints.mustSpendScriptOutput oref (Redeemer (toBuiltinData ())) <>
                payBackTokens

    ledgerTx <- submitTxConstraintsWith @Void lookups tx
    void $ awaitTxConfirmed $ txId ledgerTx
    Contract.logInfo @String $ printf "minted %s" (show fractions)


returnNFT :: AssetClass -> Contract w FracNFTSchema Text ()
returnNFT nftAsset = do
  -- pay nft to signer
  -- burn tokens
    pk    <- Contract.ownPubKey
    utxos <- utxosAt $ fractionNftValidatorAddress nftAsset
    let
      -- declare the NFT value
      valueToWallet = assetClassValue nftAsset 1
      -- find the UTxO that has the NFT we're looking for
      utxos' = Map.filter (\v -> valueToWallet == txOutValue (toTxOut v)) utxos
      (nftRef,nftTx) = head $ Map.toList utxos'
      -- use the auxiliary extractData function to get the datum content
      Just FractionNFTDatum {tokensClass, totalFractions } = extractData nftTx
      -- declare the fractional tokens to burn
      (_, fractionTokenName) = unAssetClass tokensClass
      tokensCurrency =  curSymbol nftAsset totalFractions fractionTokenName
      tokensToBurn =  Value.singleton tokensCurrency fractionTokenName $ negate totalFractions

      -- build the constraints and submit
      validator = fractionValidatorScript nftAsset
      lookups = Constraints.mintingPolicy (mintFractionTokensPolicy nftAsset totalFractions fractionTokenName)  <>
                Constraints.otherScript validator <>
                Constraints.unspentOutputs utxos'

      tx      = Constraints.mustMintValue tokensToBurn <>
                Constraints.mustSpendScriptOutput nftRef ( Redeemer $ toBuiltinData () ) <>
                Constraints.mustPayToPubKey (pubKeyHash pk) valueToWallet

    ledgerTx <- submitTxConstraintsWith @Void lookups tx
    void $ awaitTxConfirmed $ txId ledgerTx
    Contract.logInfo @String $ printf "burnt %s" (show totalFractions)

endpoints :: Contract () FracNFTSchema Text ()
endpoints = forever
                $ handleError logError
                $ awaitPromise
                $ lock' `select` fractionNFT' `select` burn'
  where
    lock' = endpoint @"1-lockNFT" $ lockNFT
    fractionNFT' = endpoint @"2-fractionNFT" $ fractionNFT
    burn' = endpoint @"3-returnNFT"   $ returnNFT

mkSchemaDefinitions ''FracNFTSchema

nfts :: KnownCurrency
nfts = KnownCurrency (ValidatorHash "f") "Token" (TokenName "NFT" :| [])

mkKnownCurrencies ['nfts]
