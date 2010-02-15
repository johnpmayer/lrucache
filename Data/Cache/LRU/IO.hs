-- | This module contains an atomic wrapping of an LRU in the IO
-- monad, for mutable access in a concurrent environment.  All calls
-- preserve the same semantics as those in "Data.Cache.LRU", but performs
-- updates in place.
--
-- (This implementation uses an MVar for coarse locking. It's unclear
-- if anything else would give better performance, given that many
-- calls alter the head of the access list.)
module Data.Cache.LRU.IO
    ( AtomicLRU
    , newAtomicLRU
    , fromList
    , toList
    , maxSize
    , insert
    , lookup
    )
where

import Prelude hiding ( lookup )

import Control.Applicative ( (<$>) )
import Control.Concurrent.MVar
    ( MVar
    , newMVar
    , readMVar
    , modifyMVar
    , modifyMVar_
    )

import Data.Cache.LRU ( LRU )
import qualified Data.Cache.LRU as LRU

-- | The opaque wrapper type
newtype AtomicLRU key val = C (MVar (LRU key val))

-- | Make a new AtomicLRU with the given maximum size.
newAtomicLRU :: Ord key => Int -- ^ the maximum size
             -> IO (AtomicLRU key val)
newAtomicLRU = fmap C . newMVar . LRU.newLRU

-- | Build a new LRU from the given maximum size and list of
-- contents. See 'LRU.fromList' for the semantics.
fromList :: Ord key => Int -- ^ the maximum size
            -> [(key, val)] -> IO (AtomicLRU key val)
fromList s l = fmap C . newMVar $ LRU.fromList s l

-- | Retreive a list view of an AtomicLRU.  See 'LRU.toList' for the
-- semantics.
toList :: Ord key => AtomicLRU key val -> IO [(key, val)]
toList (C mvar) = LRU.toList <$> readMVar mvar

maxSize :: AtomicLRU key val -> IO Int
maxSize (C mvar) = LRU.maxSize <$> readMVar mvar

-- | Insert a key/value pair into an AtomicLRU.  See 'LRU.insert' for
-- the semantics.
insert :: Ord key => key -> val -> AtomicLRU key val -> IO ()
insert key val (C mvar) = modifyMVar_ mvar $ return . LRU.insert key val

-- | Look up a key in an AtomicLRU. See 'LRU.lookup' for the
-- semantics.
lookup :: Ord key => key -> AtomicLRU key val -> IO (Maybe val)
lookup key (C mvar) = modifyMVar mvar $ return . LRU.lookup key