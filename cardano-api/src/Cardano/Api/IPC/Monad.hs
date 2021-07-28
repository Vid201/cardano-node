{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}

module Cardano.Api.IPC.Monad
  ( LocalStateQueryExpr
  , sendMsgQuery
  , executeQueryLocalState
  , executeQueryLocalStateWithChainSync
  ) where

import Cardano.Api.Block
import Cardano.Api.IPC
import Control.Applicative
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Cont
import Data.Either
import Data.Function
import Data.Maybe
import Shelley.Spec.Ledger.Scripts ()
import System.IO

import qualified Ouroboros.Network.Protocol.ChainSync.Client as Net.Sync
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Client as Net.Query
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as Net.Query

-- | Monadic type for constructing local state queries.
--
-- Use 'sendMsgQuery' in a do block to construct queries of this type and convert
-- the expression to a 'Net.Query.LocalStateQueryClient' with 'setupLocalStateQueryExpr'.
newtype LocalStateQueryExpr block point query r m a = LocalStateQueryExpr
  { runLocalStateQueryExpr :: ContT (Net.Query.ClientStAcquired block point query m r) m a
  } deriving (Functor, Applicative, Monad, MonadIO)

-- | Use 'sendMsgQuery' in a do block to construct monadic local state queries.
sendMsgQuery :: Monad m => query a -> LocalStateQueryExpr block point query r m a
sendMsgQuery q = LocalStateQueryExpr . ContT $ \f -> pure $
  Net.Query.SendMsgQuery q $
    Net.Query.ClientStQuerying
    { Net.Query.recvMsgResult = f
    }

-- | Execute a local state query expression.
executeQueryLocalState
  :: LocalNodeConnectInfo mode
  -> Maybe ChainPoint
  -> (NodeToClientVersion -> LocalStateQueryExpr (BlockInMode mode) ChainPoint (QueryInMode mode) () IO a)
  -> IO (Either AcquireFailure a)
executeQueryLocalState connectInfo mpoint f = do
  resultVarQueryTipLocalState <- newEmptyTMVarIO
  waitResult <- pure $ readTMVar resultVarQueryTipLocalState

  connectToLocalNodeWithVersion
    connectInfo
    (\ntcVersion ->
      LocalNodeClientProtocols
      { localChainSyncClient    = NoLocalChainSyncClient
      , localStateQueryClient   = Just $ setupLocalStateQueryExpr waitResult mpoint resultVarQueryTipLocalState (f ntcVersion)
      , localTxSubmissionClient = Nothing
      }
    )

  atomically waitResult

-- | Execute a local state query expression concurrently with a chain sync.
executeQueryLocalStateWithChainSync
  :: LocalNodeConnectInfo mode
  -> Maybe ChainPoint
  -> (NodeToClientVersion -> LocalStateQueryExpr (BlockInMode mode) ChainPoint (QueryInMode mode) () IO a)
  -> IO (ChainTip, Either AcquireFailure a)
executeQueryLocalStateWithChainSync connectInfo mpoint f = do
  resultVarQueryTipLocalState <- newEmptyTMVarIO
  resultVarChainTip <- newEmptyTMVarIO

  waitResult <- pure $ (,)
    <$> readTMVar resultVarChainTip
    <*> readTMVar resultVarQueryTipLocalState

  connectToLocalNodeWithVersion
    connectInfo
    (\ntcVersion ->
      LocalNodeClientProtocols
      { localChainSyncClient    = LocalChainSyncClient $ chainSyncGetCurrentTip waitResult resultVarChainTip
      , localStateQueryClient   = Just $ setupLocalStateQueryExpr waitResult mpoint resultVarQueryTipLocalState (f ntcVersion)
      , localTxSubmissionClient = Nothing
      }
    )

  atomically waitResult

  where
    chainSyncGetCurrentTip
      :: STM b
      -> TMVar  ChainTip
      -> ChainSyncClient (BlockInMode mode) ChainPoint ChainTip IO ()
    chainSyncGetCurrentTip waitDone tipVar =
      ChainSyncClient $ pure clientStIdle
      where
        clientStIdle :: Net.Sync.ClientStIdle (BlockInMode mode) ChainPoint ChainTip IO ()
        clientStIdle =
          Net.Sync.SendMsgRequestNext clientStNext (pure clientStNext)

        clientStNext :: Net.Sync.ClientStNext (BlockInMode mode) ChainPoint ChainTip IO ()
        clientStNext = Net.Sync.ClientStNext
          { Net.Sync.recvMsgRollForward = \_block tip -> ChainSyncClient $ do
              void . atomically $ putTMVar tipVar tip
              void $ atomically waitDone
              pure $ Net.Sync.SendMsgDone ()
          , Net.Sync.recvMsgRollBackward = \_point tip -> ChainSyncClient $ do
              void . atomically $ putTMVar tipVar tip
              void $ atomically waitDone
              pure $ Net.Sync.SendMsgDone ()
          }

-- | Use 'sendMsgQuery' in a do block to construct monadic local state queries.
setupLocalStateQueryExpr ::
     STM x
  -> Maybe ChainPoint
  -> TMVar (Either Net.Query.AcquireFailure a)
  -> LocalStateQueryExpr (BlockInMode mode) ChainPoint (QueryInMode mode) () IO a
  -> Net.Query.LocalStateQueryClient (BlockInMode mode) ChainPoint (QueryInMode mode) IO ()
setupLocalStateQueryExpr waitDone mPointVar' resultVar' f =
  LocalStateQueryClient . pure . Net.Query.SendMsgAcquire mPointVar' $
    Net.Query.ClientStAcquiring
    { Net.Query.recvMsgAcquired = runContT (runLocalStateQueryExpr f) $ \result -> do
        atomically $ putTMVar resultVar' (Right result)
        void $ atomically waitDone
        pure $ Net.Query.SendMsgRelease $ pure $ Net.Query.SendMsgDone ()

    , Net.Query.recvMsgFailure = \failure -> do
        atomically $ putTMVar resultVar' (Left failure)
        void $ atomically waitDone
        pure $ Net.Query.SendMsgDone ()
    }