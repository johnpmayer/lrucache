-- | Implements an LRU cache.
--
-- This module provides a pure LRU cache based on a doubly-linked list
-- through a Data.Map structure.  This gives O(log n) operations on
-- 'insert' and 'lookup', and O(n) for 'toList'.
--
-- The interface this module provides is opaque.  If further control
-- is desired, the "Data.Cache.LRU.Internal" module can be used.
module Data.Cache.LRU
    ( LRU
    , newLRU
    , fromList
    , toList
    , maxSize
    , insert
    , lookup
    )
where

import Prelude hiding ( lookup )

import Data.Cache.LRU.Internal