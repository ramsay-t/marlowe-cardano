{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

module Control.Monad.Trans.Marlowe.Class where

import Cardano.Api (BabbageEra, Tx)
import Control.Concurrent (threadDelay)
import Control.Monad (join)
import Control.Monad.Identity (IdentityT (..))
import Control.Monad.Trans.Marlowe
import Control.Monad.Trans.Reader (ReaderT (..))
import Control.Monad.Trans.Resource.Internal (ResourceT (..))
import Data.Coerce (coerce)
import Data.Foldable (asum)
import Data.Map (Map)
import Data.Time (UTCTime)
import Language.Marlowe.Object.Types (Label, ObjectBundle (..))
import Language.Marlowe.Protocol.Client (MarloweRuntimeClient (..), hoistMarloweRuntimeClient)
import Language.Marlowe.Protocol.HeaderSync.Client (MarloweHeaderSyncClient)
import Language.Marlowe.Protocol.Load.Client (MarloweLoadClient, pushContract)
import Language.Marlowe.Protocol.Query.Client (MarloweQueryClient)
import Language.Marlowe.Protocol.Sync.Client (MarloweSyncClient)
import Language.Marlowe.Protocol.Transfer.Client (
  ClientStCanDownload (..),
  ClientStCanUpload (..),
  ClientStDownload (..),
  ClientStExport (..),
  ClientStIdle (..),
  ClientStUpload (..),
  MarloweTransferClient (MarloweTransferClient),
 )
import Language.Marlowe.Protocol.Transfer.Types (ImportError)
import Language.Marlowe.Runtime.ChainSync.Api (BlockHeader, DatumHash, Lovelace, StakeCredential, TokenName, TxId)
import Language.Marlowe.Runtime.Contract.Api (ContractRequest)
import Language.Marlowe.Runtime.Core.Api (
  Contract,
  ContractId,
  Inputs,
  MarloweTransactionMetadata,
  MarloweVersion,
  MarloweVersionTag (..),
 )
import Language.Marlowe.Runtime.Transaction.Api (
  ApplyInputsError,
  ContractCreated,
  CreateError,
  InputsApplied,
  JobId (..),
  MarloweTxCommand (..),
  RoleTokensConfig,
  SubmitError,
  SubmitStatus,
  WalletAddresses,
  WithdrawError,
  WithdrawTx,
 )
import Network.Protocol.Connection (runConnector)
import Network.Protocol.Job.Client (ClientStAwait (..), ClientStInit (..), JobClient (..), liftCommand)
import qualified Network.Protocol.Job.Client as Job
import Network.Protocol.Query.Client (QueryClient)
import Numeric.Natural (Natural)
import Pipes (Pipe, Producer, await, yield)
import qualified Pipes.Internal as PI
import UnliftIO (
  MonadIO,
  MonadUnliftIO,
  SomeException (..),
  atomically,
  catch,
  liftIO,
  newEmptyTMVar,
  newIORef,
  newTChan,
  putTMVar,
  readIORef,
  readTChan,
  takeTMVar,
  throwIO,
  throwTo,
  writeIORef,
  writeTChan,
 )
import UnliftIO.Concurrent (forkFinally)

-- | A class for monadic contexts that provide a connection to a Marlowe
-- Runtime instance.
class (Monad m) => MonadMarlowe m where
  -- | Run a client of the Marlowe protocol.
  runMarloweRuntimeClient :: MarloweRuntimeClient m a -> m a

instance (MonadUnliftIO m) => MonadMarlowe (MarloweT m) where
  runMarloweRuntimeClient client = MarloweT $ ReaderT \connector ->
    runConnector connector $ hoistMarloweRuntimeClient (flip runMarloweT connector) client

instance (MonadMarlowe m) => MonadMarlowe (ReaderT r m) where
  runMarloweRuntimeClient client = ReaderT \r ->
    runMarloweRuntimeClient $ hoistMarloweRuntimeClient (flip runReaderT r) client

instance (MonadMarlowe m) => MonadMarlowe (ResourceT m) where
  runMarloweRuntimeClient client = ResourceT \rm ->
    runMarloweRuntimeClient $ hoistMarloweRuntimeClient (flip unResourceT rm) client

instance (MonadMarlowe m) => MonadMarlowe (IdentityT m) where
  runMarloweRuntimeClient = coerce runMarloweRuntimeClient

instance (MonadUnliftIO m, MonadMarlowe m) => MonadMarlowe (PI.Proxy a' a b' b m) where
  runMarloweRuntimeClient client = PI.M $ join $ atomically do
    upstreamOutChan <- newTChan
    upstreamInChan <- newTChan
    downstreamOutChan <- newTChan
    downstreamInChan <- newTChan
    resultVar <- newEmptyTMVar
    let mkProxy clientThread = PI.M do
          let clientAction =
                atomically $
                  asum
                    [ do
                        a' <- readTChan upstreamOutChan
                        pure $ PI.Request a' \a -> PI.M do
                          atomically $ writeTChan upstreamInChan a
                          pure $ mkProxy clientThread
                    , do
                        b <- readTChan downstreamOutChan
                        pure $ PI.Respond b \b' -> PI.M do
                          atomically $ writeTChan downstreamInChan b'
                          pure $ mkProxy clientThread
                    , do
                        result <- takeTMVar resultVar
                        pure case result of
                          Left (SomeException e) -> PI.M $ throwIO e
                          Right a -> PI.Pure a
                    ]
          clientAction `catch` \(SomeException e) -> do
            throwTo clientThread e
            throwIO e
        elimProxy :: PI.Proxy a' a b' b m r -> m r
        elimProxy = \case
          PI.Request a' k -> do
            atomically $ writeTChan upstreamOutChan a'
            a <- atomically $ readTChan upstreamInChan
            elimProxy $ k a
          PI.Respond b k -> do
            atomically $ writeTChan downstreamOutChan b
            b' <- atomically $ readTChan downstreamInChan
            elimProxy $ k b'
          PI.M m -> elimProxy =<< m
          PI.Pure r -> pure r
    pure $
      fmap mkProxy $
        forkFinally (runMarloweRuntimeClient $ hoistMarloweRuntimeClient elimProxy client) $
          atomically . putTMVar resultVar

-- | Run a MarloweSyncClient. Used to synchronize with history for a specific
-- contract.
runMarloweSyncClient :: (MonadMarlowe m) => MarloweSyncClient m a -> m a
runMarloweSyncClient = runMarloweRuntimeClient . RunMarloweSyncClient

-- | Run a MarloweHeaderSyncClient. Used to synchronize with contract creation
-- transactions.
runMarloweHeaderSyncClient :: (MonadMarlowe m) => MarloweHeaderSyncClient m a -> m a
runMarloweHeaderSyncClient = runMarloweRuntimeClient . RunMarloweHeaderSyncClient

-- | Run a MarloweQueryClient.
runMarloweQueryClient :: (MonadMarlowe m) => MarloweQueryClient m a -> m a
runMarloweQueryClient = runMarloweRuntimeClient . RunMarloweQueryClient

-- | Run a ContractQueryClient.
runContractQueryClient :: (MonadMarlowe m) => QueryClient ContractRequest m a -> m a
runContractQueryClient = runMarloweRuntimeClient . RunContractQueryClient

-- | Run a MarloweLoadClient.
runMarloweLoadClient :: (MonadMarlowe m) => MarloweLoadClient m a -> m a
runMarloweLoadClient = runMarloweRuntimeClient . RunMarloweLoadClient

-- | Run a MarloweTransferClient.
runMarloweTransferClient :: (MonadMarlowe m) => MarloweTransferClient m a -> m a
runMarloweTransferClient = runMarloweRuntimeClient . RunMarloweTransferClient

-- | Run a MarloweTxCommand job client.
runMarloweTxClient :: (MonadMarlowe m) => JobClient MarloweTxCommand m a -> m a
runMarloweTxClient = runMarloweRuntimeClient . RunTxClient

-- | Load a contract incrementally into the runtime, obtaining the hash of the
-- deeply merkleized version of the contract. Returns nothing if the contract
-- is already merkleized.
loadContract :: (MonadMarlowe m) => Contract 'V1 -> m (Maybe DatumHash)
loadContract = runMarloweLoadClient . pushContract

-- | Import a single object bundle into the Runtime. It will incrementally link the bundle, merkleize the contracts, and
-- save them to the store. Returns a mapping of the original contract labels to their store hashes.
importBundle :: (MonadMarlowe m) => ObjectBundle -> m (Either ImportError (Map Label DatumHash))
importBundle bundle =
  runMarloweTransferClient $
    MarloweTransferClient $
      pure $
        SendMsgStartImport $
          SendMsgUpload
            bundle
            ClientStUpload
              { recvMsgUploadFailed = pure . SendMsgDone . Left
              , recvMsgUploaded = pure . SendMsgImported . SendMsgDone . Right
              }

-- | Stream a multi-part object bundle into the Runtime. It will link the bundle, merkleize the contracts, and
-- save them to the store. Yields mappings of the original contract labels to their store hashes.
importIncremental :: (MonadUnliftIO m, MonadMarlowe m) => Pipe ObjectBundle (Map Label DatumHash) m (Maybe ImportError)
importIncremental = runMarloweTransferClient $ MarloweTransferClient $ SendMsgStartImport . upload <$> await
  where
    upload bundle =
      SendMsgUpload
        bundle
        ClientStUpload
          { recvMsgUploadFailed = pure . SendMsgDone . Just
          , recvMsgUploaded = \hashes -> do
              yield hashes
              nextBundle <- await
              pure $ upload nextBundle
          }

-- | Export a contract from the runtime as a single object bundle. The first argument controls the batch size.
exportContract :: (MonadMarlowe m) => Natural -> DatumHash -> m (Maybe ObjectBundle)
exportContract batchSize hash =
  runMarloweTransferClient $
    MarloweTransferClient $
      pure $
        SendMsgRequestExport
          hash
          ClientStExport
            { recvMsgStartExport = do
                let downloadLoop acc =
                      SendMsgDownload
                        batchSize
                        ClientStDownload
                          { recvMsgDownloaded = \(ObjectBundle bundle) -> pure $ downloadLoop $ acc <> bundle
                          , recvMsgExported = pure $ SendMsgDone $ Just $ ObjectBundle acc
                          }
                pure $ downloadLoop []
            , recvMsgContractNotFound = pure $ SendMsgDone Nothing
            }

-- | Stream a contract from the runtime as a multi-part object bundle. The first argument controls the batch size of the
-- bundles.
exportIncremental :: (MonadMarlowe m, MonadUnliftIO m) => Natural -> DatumHash -> Producer ObjectBundle m Bool
exportIncremental batchSize hash =
  runMarloweTransferClient $
    MarloweTransferClient $
      pure $
        SendMsgRequestExport
          hash
          ClientStExport
            { recvMsgStartExport = do
                let downloadLoop =
                      SendMsgDownload
                        batchSize
                        ClientStDownload
                          { recvMsgDownloaded = \bundle -> do
                              yield bundle
                              pure downloadLoop
                          , recvMsgExported = pure $ SendMsgDone True
                          }
                pure downloadLoop
            , recvMsgContractNotFound = pure $ SendMsgDone False
            }

-- | Create a new contract.
createContract
  :: (MonadMarlowe m)
  => Maybe StakeCredential
  -- ^ A reference to the stake address to use for script addresses.
  -> MarloweVersion v
  -- ^ The Marlowe version to use
  -> WalletAddresses
  -- ^ The wallet addresses to use when constructing the transaction
  -> RoleTokensConfig
  -- ^ How to initialize role tokens
  -> MarloweTransactionMetadata
  -- ^ Optional metadata to attach to the transaction
  -> Lovelace
  -- ^ Min Lovelace which should be used for the contract output.
  -> Either (Contract v) DatumHash
  -- ^ The contract to run, or the hash of the contract to look up in the store.
  -> m (Either (CreateError v) (ContractCreated BabbageEra v))
createContract mStakeCredential version wallet roleTokens metadata lovelace contract =
  runMarloweTxClient $
    liftCommand $
      Create
        mStakeCredential
        version
        wallet
        roleTokens
        metadata
        lovelace
        contract

-- | Apply inputs to a contract, with custom validity interval bounds.
applyInputs'
  :: (MonadMarlowe m)
  => MarloweVersion v
  -- ^ The Marlowe version to use
  -> WalletAddresses
  -- ^ The wallet addresses to use when constructing the transaction
  -> ContractId
  -- ^ The ID of the contract to apply the inputs to.
  -> MarloweTransactionMetadata
  -- ^ Optional metadata to attach to the transaction
  -> Maybe UTCTime
  -- ^ The "invalid before" bound of the validity interval. If omitted, this
  -- is computed from the contract.
  -> Maybe UTCTime
  -- ^ The "invalid hereafter" bound of the validity interval. If omitted, this
  -- is computed from the contract.
  -> Inputs v
  -- ^ The inputs to apply.
  -> m (Either (ApplyInputsError v) (InputsApplied BabbageEra v))
applyInputs' version wallet contractId metadata invalidBefore invalidHereafter inputs =
  runMarloweTxClient $
    liftCommand $
      ApplyInputs
        version
        wallet
        contractId
        metadata
        invalidBefore
        invalidHereafter
        inputs

-- | Apply inputs to a contract.
applyInputs
  :: (MonadMarlowe m)
  => MarloweVersion v
  -- ^ The Marlowe version to use
  -> WalletAddresses
  -- ^ The wallet addresses to use when constructing the transaction
  -> ContractId
  -- ^ The ID of the contract to apply the inputs to.
  -> MarloweTransactionMetadata
  -- ^ Optional metadata to attach to the transaction
  -> Inputs v
  -- ^ The inputs to apply.
  -> m (Either (ApplyInputsError v) (InputsApplied BabbageEra v))
applyInputs version wallet contractId metadata =
  applyInputs' version wallet contractId metadata Nothing Nothing

-- | Withdraw funds that have been paid out to a role in a contract.
withdraw
  :: (MonadMarlowe m)
  => MarloweVersion v
  -- ^ The Marlowe version to use
  -> WalletAddresses
  -- ^ The wallet addresses to use when constructing the transaction
  -> ContractId
  -- ^ The ID of the contract to apply the inputs to.
  -> TokenName
  -- ^ The names of the roles whose assets to withdraw.
  -> m (Either (WithdrawError v) (WithdrawTx BabbageEra v))
withdraw version wallet contractId role =
  runMarloweTxClient $ liftCommand $ Withdraw version wallet contractId role

-- | Submit a signed transaction via the Marlowe Runtime. Waits for completion
-- with exponential back-off in the polling.
submitAndWait
  :: (MonadMarlowe m, MonadIO m)
  => Tx BabbageEra
  -- ^ The transaction to submit.
  -> m (Either SubmitError BlockHeader)
submitAndWait tx = do
  delayRef <- liftIO $ newIORef 1000
  submit (onAwait delayRef) (pure . Left) (pure . Right) tx
  where
    onAwait delayRef _ _ = liftIO do
      delay <- readIORef delayRef
      threadDelay delay
      writeIORef delayRef (min 1_000_000 $ delay * 10)
      pure Nothing

-- | Submit a signed transaction via the Marlowe Runtime. If it does not complete
-- immediately, it will not wait for completion, and a TxId will be returned
-- which can be used to check progress later via @attachSubmit@.
submitAndDetach
  :: (MonadMarlowe m)
  => Tx BabbageEra
  -- ^ The transaction to submit.
  -> m (Either TxId (Either SubmitError BlockHeader))
submitAndDetach = submit (const . pure . Just . Left) (pure . Right . Left) (pure . Right . Right)

-- | Submit a signed transaction via the Marlowe Runtime.
submit
  :: (MonadMarlowe m)
  => (TxId -> SubmitStatus -> m (Maybe a))
  -- ^ Handle being told to wait. Receives the ID of the transaction (which can
  -- be used to attach later via @attachSubmit@) and the status of the
  -- submission.
  -> (SubmitError -> m a)
  -- ^ Handle a submit failure.
  -> (BlockHeader -> m a)
  -- ^ Handle submission success. Receives the block header of the block the
  -- transaction was seen to have been published on. Note: this block could be
  -- rolled back, in which case the block header would change and the
  -- transaction may not exist anymore.
  -> Tx BabbageEra
  -- ^ The transaction to submit.
  -> m a
submit onAwait onFail onSuccess tx =
  runMarloweTxClient $ JobClient $ pure $ SendMsgExec (Submit tx) clientCmd
  where
    clientCmd =
      Job.ClientStCmd
        { recvMsgFail = onFail
        , recvMsgSucceed = onSuccess
        , recvMsgAwait = \status (JobIdSubmit txId) -> do
            result <- onAwait txId status
            pure case result of
              Nothing -> SendMsgPoll clientCmd
              Just a -> SendMsgDetach a
        }

-- | Attach to a previously launched tx submission job. Returns @Nothing@ if
-- the submission job couldn't be found.
attachSubmit
  :: (MonadMarlowe m)
  => (SubmitStatus -> m (Maybe a))
  -- ^ Progress callback.
  -> (SubmitError -> m a)
  -- ^ Handle a submit failure.
  -> (BlockHeader -> m a)
  -- ^ Handle submission success. Receives the block header of the block the
  -- transaction was seen to have been published on. Note: this block could be
  -- rolled back, in which case the block header would change and the
  -- transaction may not exist anymore.
  -> TxId
  -- ^ The ID of the transaction whose submission job to attach to.
  -> m (Maybe a)
attachSubmit onAwait onFail onSuccess txId =
  runMarloweTxClient $
    JobClient $
      pure $
        SendMsgAttach
          (JobIdSubmit txId)
          Job.ClientStAttach
            { recvMsgAttachFailed = pure Nothing
            , recvMsgAttached = pure $ Just <$> clientCmd
            }
  where
    clientCmd =
      Job.ClientStCmd
        { recvMsgFail = onFail
        , recvMsgSucceed = onSuccess
        , recvMsgAwait = \status _ -> do
            result <- onAwait status
            pure case result of
              Nothing -> SendMsgPoll clientCmd
              Just a -> SendMsgDetach a
        }
