{-# LANGUAGE Arrows #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Main where

import Cardano.Api (
  CardanoEra (..),
  CardanoMode,
  ConsensusModeParams (..),
  EpochSlots (..),
  EraInMode (..),
  File (..),
  LocalNodeConnectInfo (..),
  TxInMode (..),
 )
import qualified Cardano.Api as Cardano (connectToLocalNode)
import Control.Concurrent.Component
import Control.Concurrent.Component.Probes (ProbeServerDependencies (..), probeServer)
import Control.Concurrent.Component.Run (runAppMTraced)
import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (MonadReader (..))
import Data.String (IsString (fromString))
import qualified Data.Text as T
import Data.Version (showVersion)
import Database.PostgreSQL.LibPQ (db, user)
import qualified Database.PostgreSQL.LibPQ as PQ
import Hasql.Connection (withLibPQConnection)
import qualified Hasql.Pool as Pool
import Language.Marlowe.Runtime.ChainSync (ChainSync (..), ChainSyncDependencies (..), chainSync)
import Language.Marlowe.Runtime.ChainSync.Api (WithGenesis (..))
import qualified Language.Marlowe.Runtime.ChainSync.Database.PostgreSQL as PostgreSQL
import Language.Marlowe.Runtime.ChainSync.NodeClient (NodeClient (..), NodeClientDependencies (..), nodeClient)
import Logging (RootSelector (..), renderRootSelectorOTel)
import Network.Protocol.ChainSeek.Server (chainSeekServerPeer)
import qualified Network.Protocol.ChainSeek.Types as ChainSeek
import Network.Protocol.Connection (ServerSource (..), ServerSourceTraced (ServerSourceTraced))
import Network.Protocol.Driver (TcpServerDependencies (..))
import Network.Protocol.Driver.Trace (tcpServerTraced)
import Network.Protocol.Job.Server (jobServerPeer)
import Network.Protocol.Peer.Monad.TCP (TcpServerPeerTDependencies (..), tcpServerPeerT)
import Network.Protocol.Query.Server (queryServerPeerT)
import qualified Network.Protocol.Query.Types as Query
import Observe.Event.Explicit (injectSelector)
import OpenTelemetry.Trace
import Options (Options (..), getOptions)
import Paths_marlowe_chain_sync (version)
import UnliftIO (throwIO)

main :: IO ()
main = run =<< getOptions (showVersion version)

run :: Options -> IO ()
run Options{..} = bracket (Pool.acquire 100 (Just 5000000) (fromString databaseUri)) Pool.release \pool -> do
  (dbName, dbUser, dbHost, dbPort) <-
    either throwIO pure =<< Pool.use pool do
      connection <- ask
      liftIO $ withLibPQConnection connection \conn ->
        (,,,)
          <$> db conn
          <*> user conn
          <*> PQ.host conn
          <*> PQ.port conn
  runAppMTraced instrumentationLibrary (renderRootSelectorOTel dbName dbUser dbHost dbPort) $
    runComponent_ appComponent pool
  where
    instrumentationLibrary =
      InstrumentationLibrary
        { libraryName = "marlowe-chain-sync"
        , libraryVersion = T.pack $ showVersion version
        }

    appComponent = proc pool -> do
      NodeClient{..} <-
        nodeClient
          -<
            NodeClientDependencies
              { connectToLocalNode = liftIO . Cardano.connectToLocalNode localNodeConnectInfo
              }

      ChainSync{..} <-
        chainSync
          -<
            ChainSyncDependencies
              { databaseQueries = PostgreSQL.databaseQueries pool networkId
              , queryLocalNodeState = queryNode
              , submitTxToNodeLocal = \era tx -> submitTxToNode $ TxInMode tx case era of
                  ByronEra -> ByronEraInCardanoMode
                  ShelleyEra -> ShelleyEraInCardanoMode
                  AllegraEra -> AllegraEraInCardanoMode
                  MaryEra -> MaryEraInCardanoMode
                  AlonzoEra -> AlonzoEraInCardanoMode
                  BabbageEra -> BabbageEraInCardanoMode
                  ConwayEra -> ConwayEraInCardanoMode
              , nodeTip
              , scanBatchSize = 8192 -- TODO make this a command line option
              }

      tcpServerPeerT "chain-seek" $ injectSelector ChainSeekServer
        -<
          TcpServerPeerTDependencies
            { host
            , port
            , nobodyHasAgency = ChainSeek.TokDone
            , serverSource = ServerSourceTraced \inj -> do
                server <- getServer syncServerSource
                pure $ chainSeekServerPeer Genesis inj server
            }

      tcpServerPeerT "query" $ injectSelector QueryServer
        -<
          TcpServerPeerTDependencies
            { host
            , port = queryPort
            , nobodyHasAgency = Query.TokDone
            , serverSource = ServerSourceTraced \inj -> do
                server <- getServer queryServerSource
                pure $ queryServerPeerT inj server
            }

      tcpServerTraced "chain-job" $ injectSelector JobServer
        -<
          TcpServerDependencies
            { host
            , port = commandPort
            , toPeer = jobServerPeer
            , serverSource = jobServerSource
            }

      probeServer -< ProbeServerDependencies{port = fromIntegral httpPort, ..}

    localNodeConnectInfo :: LocalNodeConnectInfo CardanoMode
    localNodeConnectInfo =
      LocalNodeConnectInfo
        { -- The epoch slots ignored after Byron.
          localConsensusModeParams = CardanoModeParams $ EpochSlots 21600
        , localNodeNetworkId = networkId
        , localNodeSocketPath = File nodeSocket
        }
