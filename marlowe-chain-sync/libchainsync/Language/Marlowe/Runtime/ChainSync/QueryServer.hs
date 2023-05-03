{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StrictData #-}

module Language.Marlowe.Runtime.ChainSync.QueryServer
  where

import Cardano.Api
  ( AnyCardanoEra(..)
  , CardanoMode
  , ConsensusMode(..)
  , ConsensusModeIsMultiEra(..)
  , EraInMode(..)
  , GenesisParameters(..)
  , QueryInEra(..)
  , QueryInMode(..)
  , QueryInShelleyBasedEra(..)
  , ShelleyBasedEra(..)
  , toEraInMode
  )
import qualified Cardano.Api as Cardano
import Cardano.Api.Shelley (AcquiringFailure)
import Control.Concurrent.Component
import Control.Monad.Trans.Except (ExceptT(ExceptT), except, runExceptT, throwE, withExceptT)
import Data.Bifunctor (first)
import Data.Void (Void, absurd)
import Language.Marlowe.Runtime.ChainSync.Api (ChainSyncQuery(..))
import qualified Language.Marlowe.Runtime.ChainSync.Database as Database
import Network.Protocol.Connection (SomeConnectionSource, SomeServerConnector, acceptSomeConnector)
import Network.Protocol.Driver (runSomeConnector)
import Network.Protocol.Query.Server (QueryServer(..), ServerStInit(..), ServerStNext(..), ServerStPage(..))
import Network.Protocol.Query.Types (StNextKind(..))
import UnliftIO (MonadUnliftIO)

data ChainSyncQueryServerDependencies m = ChainSyncQueryServerDependencies
  { querySource :: SomeConnectionSource (QueryServer ChainSyncQuery) m
  , queryLocalNodeState
      :: forall result
       . Maybe Cardano.ChainPoint
      -> QueryInMode CardanoMode result
      -> m (Either AcquiringFailure result)
  , getUTxOs :: Database.GetUTxOs m
  }

chainSyncQueryServer :: MonadUnliftIO m => Component m (ChainSyncQueryServerDependencies m) ()
chainSyncQueryServer = serverComponent worker \ChainSyncQueryServerDependencies{..} -> do
  connector <- acceptSomeConnector querySource
  pure WorkerDependencies {..}

data WorkerDependencies m = WorkerDependencies
  { connector :: SomeServerConnector (QueryServer ChainSyncQuery) m
  , queryLocalNodeState
      :: forall result
       . Maybe Cardano.ChainPoint
      -> QueryInMode CardanoMode result
      -> m (Either AcquiringFailure result)
  , getUTxOs :: Database.GetUTxOs m
  }

worker :: forall m. MonadUnliftIO m => Component m (WorkerDependencies m) ()
worker = component_ \WorkerDependencies{..} -> do
  let
    server :: QueryServer ChainSyncQuery m ()
    server = QueryServer $ pure $ ServerStInit \case
      GetSecurityParameter -> queryGenesisParameters protocolParamSecurity
      GetNetworkId -> queryGenesisParameters protocolParamNetworkId
      GetProtocolParameters -> toServerStNext <$> queryShelley (const QueryProtocolParameters)
      GetSystemStart ->
        toServerStNext . first (const ()) <$> queryLocalNodeState Nothing QuerySystemStart
      GetEraHistory ->
        toServerStNext . first (const ()) <$> queryLocalNodeState Nothing (QueryEraHistory CardanoModeIsMultiEra)
      GetUTxOs utxosQuery -> do
        utxos <- Database.runGetUTxOs getUTxOs utxosQuery
        pure $ toServerStNext $ Right utxos

    toServerStNext :: Either () a -> ServerStNext ChainSyncQuery 'CanReject Void () a m ()
    toServerStNext = \case
      Left _ -> SendMsgReject () ()
      Right a -> SendMsgNextPage a Nothing $ ServerStPage
        { recvMsgDone = pure ()
        , recvMsgRequestNext = absurd
        }

    queryGenesisParameters :: (GenesisParameters -> a) -> m (ServerStNext ChainSyncQuery 'CanReject Void () a m ())
    queryGenesisParameters f = toServerStNext . fmap f <$> queryShelley (const QueryGenesisParameters)

    queryShelley
      :: (forall era. ShelleyBasedEra era -> QueryInShelleyBasedEra era result)
      -> m (Either () result)
    queryShelley query = runExceptT do
      AnyCardanoEra era <- withExceptT (const ())
        $ ExceptT
        $ queryLocalNodeState Nothing
        $ QueryCurrentEra CardanoModeIsMultiEra
      eraInMode <- case toEraInMode era CardanoMode of
        Nothing        -> throwE ()
        Just eraInMode -> pure eraInMode
      shelleyBasedEra <- case eraInMode of
        ByronEraInCardanoMode   -> throwE ()
        ShelleyEraInCardanoMode -> pure ShelleyBasedEraShelley
        AllegraEraInCardanoMode -> pure ShelleyBasedEraAllegra
        MaryEraInCardanoMode    -> pure ShelleyBasedEraMary
        AlonzoEraInCardanoMode  -> pure ShelleyBasedEraAlonzo
        BabbageEraInCardanoMode -> pure ShelleyBasedEraBabbage
      result <- withExceptT (const ())
        $ ExceptT
        $ queryLocalNodeState Nothing
        $ QueryInEra eraInMode
        $ QueryInShelleyBasedEra shelleyBasedEra $ query shelleyBasedEra
      withExceptT (const ()) $ except result
  runSomeConnector connector server
