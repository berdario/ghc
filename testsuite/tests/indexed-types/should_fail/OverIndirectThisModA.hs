{-# LANGUAGE TypeFamilies #-}

module OverIndirectThisModA (C, D)
where

import Data.Kind (Type)

data family C a b :: Type

type family D a b :: Type
