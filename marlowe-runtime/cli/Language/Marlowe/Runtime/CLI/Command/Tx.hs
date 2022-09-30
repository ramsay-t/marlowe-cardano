module Language.Marlowe.Runtime.CLI.Command.Tx
  where

import qualified Data.Set as Set
import Language.Marlowe.Runtime.CLI.Option (parseAddress, txOutRefParser)
import Language.Marlowe.Runtime.Transaction.Api (WalletAddresses(WalletAddresses))
import Options.Applicative

data TxCommand cmd = TxCommand
  { walletAddresses :: WalletAddresses
  , signingMethod :: SigningMethod
  , metadataFile :: Maybe FilePath
  , subCommand :: cmd
  }

newtype SigningMethod
  = Manual FilePath

txCommandParser :: Parser cmd -> Parser (TxCommand cmd)
txCommandParser subCommandParser = TxCommand
  <$> walletAddressesParser
  <*> signingMethodParser
  <*> metadataFileParser
  <*> subCommandParser
  where
    walletAddressesParser = WalletAddresses
      <$> changeAddressParser
      <*> extraAddressesParser
      <*> collateralUtxosParser
    -- TODO add other signing methods with <|> here (e.g. CIP-30, cardano-wallet).
    signingMethodParser = manualSignParser
    manualSignParser = fmap Manual $ strOption $ mconcat
      [ long "manual-sign"
      , help "Sign the transaction manually. Writes the CBOR bytes of the unsigned transaction to the specified file for manual signing. Use the submit command to submit the signed transaction."
      ]
    metadataFileParser = optional $ strOption $ mconcat
      [ long "metadata-file"
      , short 'm'
      , help "A JSON file containing a map of integer indexes to arbitrary JSON values that will be added to the transaction's metadata."
      , metavar "FILE_PATH"
      ]
    changeAddressParser = option (eitherReader parseAddress) $ mconcat
      [ long "change-address"
      , help "The address to which the change of the transaction should be sent."
      , metavar "ADDRESS"
      ]
    extraAddressesParser = fmap Set.fromList $ many $ option (eitherReader parseAddress) $ mconcat
      [ long "address"
      , short 'a'
      , help "An address whose UTXOs can be used as inputs to the transaction"
      , metavar "ADDRESS"
      ]
    collateralUtxosParser = fmap Set.fromList $ many $ option txOutRefParser $ mconcat
      [ long "collateral-utxo"
      , help "An UTXO which may be used for collateral"
      , metavar "UTXO"
      ]
