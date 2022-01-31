-- File auto generated by purescript-bridge! --
module Language.Marlowe.ACTUS.Domain.Schedule where

import Prelude

import Control.Lazy (defer)
import Data.Argonaut (encodeJson, jsonNull)
import Data.Argonaut.Decode (class DecodeJson)
import Data.Argonaut.Decode.Aeson ((</$\>), (</*\>), (</\>))
import Data.Argonaut.Decode.Aeson as D
import Data.Argonaut.Encode (class EncodeJson)
import Data.Argonaut.Encode.Aeson ((>$<), (>/\<))
import Data.Argonaut.Encode.Aeson as E
import Data.BigInt.Argonaut (BigInt)
import Data.Generic.Rep (class Generic)
import Data.Lens (Iso', Lens', Prism', iso, prism')
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Lens.Record (prop)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap)
import Data.Tuple.Nested ((/\))
import Language.Marlowe.ACTUS.Domain.BusinessEvents (EventType)
import Type.Proxy (Proxy(Proxy))

newtype CashFlowPoly a = CashFlowPoly
  { tick :: BigInt
  , cashContractId :: String
  , cashParty :: String
  , cashCounterParty :: String
  , cashPaymentDay :: String
  , cashCalculationDay :: String
  , cashEvent :: EventType
  , amount :: a
  , notional :: a
  , currency :: String
  }

instance (EncodeJson a) => EncodeJson (CashFlowPoly a) where
  encodeJson = defer \_ -> E.encode $ unwrap >$<
    ( E.record
        { tick: E.value :: _ BigInt
        , cashContractId: E.value :: _ String
        , cashParty: E.value :: _ String
        , cashCounterParty: E.value :: _ String
        , cashPaymentDay: E.value :: _ String
        , cashCalculationDay: E.value :: _ String
        , cashEvent: E.value :: _ EventType
        , amount: E.value :: _ a
        , notional: E.value :: _ a
        , currency: E.value :: _ String
        }
    )

instance (DecodeJson a) => DecodeJson (CashFlowPoly a) where
  decodeJson = defer \_ -> D.decode $
    ( CashFlowPoly <$> D.record "CashFlowPoly"
        { tick: D.value :: _ BigInt
        , cashContractId: D.value :: _ String
        , cashParty: D.value :: _ String
        , cashCounterParty: D.value :: _ String
        , cashPaymentDay: D.value :: _ String
        , cashCalculationDay: D.value :: _ String
        , cashEvent: D.value :: _ EventType
        , amount: D.value :: _ a
        , notional: D.value :: _ a
        , currency: D.value :: _ String
        }
    )

derive instance Generic (CashFlowPoly a) _

derive instance Newtype (CashFlowPoly a) _

--------------------------------------------------------------------------------

_CashFlowPoly
  :: forall a
   . Iso' (CashFlowPoly a)
       { tick :: BigInt
       , cashContractId :: String
       , cashParty :: String
       , cashCounterParty :: String
       , cashPaymentDay :: String
       , cashCalculationDay :: String
       , cashEvent :: EventType
       , amount :: a
       , notional :: a
       , currency :: String
       }
_CashFlowPoly = _Newtype
