module Component.CurrentStepActions.Types
  ( Action(..)
  , ComponentHTML
  , DSL
  , Input
  , Msg(..)
  , Query
  , Slot
  , State
  , _currentStepActions
  ) where

import Prologue

import Data.ContractUserParties (ContractUserParties)
import Data.Map (Map)
import Data.UserNamedActions (UserNamedActions)
import Halogen as H
import Marlowe.Execution.Types (NamedAction)
import Marlowe.Execution.Types as Execution
import Marlowe.Semantics (ChoiceId, ChosenNum)
import Type.Proxy (Proxy(..))

data Msg = ActionSelected NamedAction (Maybe ChosenNum)

data Action
  = SelectAction NamedAction (Maybe ChosenNum)
  | ChangeChoice ChoiceId (Maybe ChosenNum)

type State =
  { executionState :: Execution.State
  , contractUserParties :: ContractUserParties
  , namedActions :: UserNamedActions
  , choiceValues :: Map ChoiceId ChosenNum
  }

type Input =
  { executionState :: Execution.State
  , contractUserParties :: ContractUserParties
  , namedActions :: UserNamedActions
  }

type ComponentHTML m =
  H.ComponentHTML Action () m

type DSL m a =
  H.HalogenM State Action () Msg m a

data Query (a :: Type)

type Slot m = H.Slot Query Msg m

_currentStepActions = Proxy :: Proxy "currentStepActions"
