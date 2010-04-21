{-# OPTIONS_HADDOCK not-home #-}

-- | This module provides access to all the internals use by the LRU
-- type.  This can be used to create data structures that violate the
-- invariants the public interface maintains.  Be careful when using
-- this module.  The 'valid' function can be used to check if an LRU
-- structure satisfies the invariants the public interface maintains.
--
-- If this degree of control isn't needed, consider using
-- "Data.Cache.LRU" instead.
module Data.Cache.LRU.Internal where

import Prelude hiding ( last, lookup )

import Data.Map ( Map )
import qualified Data.Map as Map

-- | Stores the information that makes up an LRU cache
data LRU key val = LRU {
      first :: !(Maybe key) -- ^ the key of the most recently accessed entry
    , last :: !(Maybe key) -- ^ the key of the least recently accessed entry
    , maxSize :: !Int -- ^ the maximum size of the LRU cache
    , content :: !(Map key (LinkedVal key val)) -- ^ the backing 'Map'
    } deriving Eq


instance (Ord key, Show key, Show val) => Show (LRU key val) where
    show lru = "fromList " ++ show (toList lru)

-- | The values stored in the Map of the LRU cache.  They embed a
-- doubly-linked list through the values of the 'Map'.
data LinkedVal key val = Link {
      value :: val -- ^ The actual value
    , prev :: !(Maybe key) -- ^ the key of the value before this one
    , next :: !(Maybe key) -- ^ the key of the value after this one
    } deriving Eq

-- | Make an LRU.  The LRU is guaranteed to not grow above the
-- specified number of entries.
newLRU :: (Ord key) => Int -- ^ the maximum size of the LRU
       -> LRU key val
newLRU s | s <= 0 = error "non-positive size LRU"
         | otherwise = LRU Nothing Nothing s Map.empty

-- | Build a new LRU from the given maximum size and list of contents,
-- in order from most recently accessed to least recently accessed.
fromList :: Ord key => Int -- ^ the maximum size of the LRU
         -> [(key, val)] -> LRU key val
fromList s l = appendAll $ newLRU s
    where appendAll = foldr ins id l
          ins (k, v) = (insert k v .)

-- | Retrieve a list view of an LRU.  The items are returned in
-- order from most recently accessed to least recently accessed.
toList :: Ord key => LRU key val -> [(key, val)]
toList lru = maybe [] (listLinks . content $ lru) $ first lru
    where
      listLinks m key =
          let Just lv = Map.lookup key m
              keyval = (key, value lv)
          in case next lv of
               Nothing -> [keyval]
               Just nk -> keyval : listLinks m nk

-- | Add an item to an LRU.  If the key was already present in the
-- LRU, the value is changed to the new value passed in.  The
-- item added is marked as the most recently accessed item in the
-- LRU returned.
--
-- If this would cause the LRU to exceed its maximum size, the
-- least recently used item is dropped from the cache.
insert :: Ord key => key -> val -> LRU key val -> LRU key val
insert key val lru = maybe emptyCase nonEmptyCase $ first lru
    where
      contents = content lru
      full = Map.size contents == maxSize lru
      present = key `Map.member` contents

      -- this is the case for adding to an empty LRU Cache
      emptyCase = LRU fl fl (maxSize lru) m'
          where
            fl = Just key
            lv = Link val Nothing Nothing
            m' = Map.insert key lv contents

      nonEmptyCase firstKey = if present then hitSet else add firstKey

      -- this updates the value stored with the key, then marks it as
      -- the most recently accessed
      hitSet = hit' key lru'
          where lru' = lru { content = contents' }
                contents' = adjust' (\v -> v {value = val}) key contents

      -- create a new LRU with a new first item, and
      -- conditionally dropping the last item
      add firstKey = if full then lru'' else lru'
          where
            -- add a new first item
            firstLV' = Link val Nothing $ Just firstKey
            contents' = Map.insert key firstLV' .
                        adjust' (\v -> v { prev = Just key }) firstKey $
                        contents
            lru' = lru { first = Just key, content = contents' }

            -- remove the last item
            Just lastKey = last lru'
            Just lastLV = Map.lookup lastKey contents'
            contents'' = Map.delete lastKey contents'
            lru'' = delete' lastKey lru' contents'' lastLV

-- | Look up an item in an LRU.  If it was present, it is marked as
-- the most recently accesed in the returned LRU.
lookup :: Ord key => key -> LRU key val -> (LRU key val, Maybe val)
lookup key lru = case Map.lookup key $ content lru of
                           Nothing -> (lru, Nothing)
                           Just lv -> (hit' key lru, Just . value $ lv)

-- | Remove an item from an LRU.  Returns the new LRU, and if the item
-- was present to be removed.
delete :: Ord key => key -> LRU key val -> (LRU key val, Bool)
delete key lru = maybe (lru, False) delete'' mLV
    where
      delete'' = flip (,) True . delete' key lru cont'
      (mLV, cont') = Map.updateLookupWithKey (\_ _ -> Nothing) key $ content lru

-- | Returns the number of elements the LRU currently contains.
size :: LRU key val -> Int
size = Map.size . content

-- | Internal function.  The key passed in must be present in the
-- LRU.  Moves the item associated with that key to the most
-- recently accessed position.
hit' :: Ord key => key -> LRU key val -> LRU key val
hit' key lru = if key == firstKey then lru else notFirst
    where Just firstKey = first lru
          Just lastKey = last lru
          Just lastLV = Map.lookup lastKey conts
          conts = content lru

          -- key wasn't already the head of the list.  Some alteration
          -- will be needed
          notFirst = if key == lastKey then replaceLast else replaceMiddle

          adjFront = adjust' (\v -> v { prev = Just key}) firstKey .
                     adjust' (\v -> v { prev = Nothing
                                      , next = first lru }) key

          -- key was the last entry in the list
          replaceLast = lru { first = Just key
                            , last = prev lastLV
                            , content = cLast
                            }
          Just pKey = prev lastLV
          cLast = adjust' (\v -> v { next = Nothing }) pKey . adjFront $ conts

          -- the key wasn't the first or last key
          replaceMiddle = lru { first = Just key
                              , content = cMid
                              }
          Just keyLV = Map.lookup key conts
          Just prevKey = prev keyLV
          Just nextKey = next keyLV
          cMid = adjust' (\v -> v { next = Just nextKey }) prevKey .
                 adjust' (\v -> v { prev = Just prevKey }) nextKey .
                 adjFront $ conts

-- | An internal function used by 'insert' (when the cache is full)
-- and 'delete'.  This function has strict requirements on its
-- arguments in order to work properly.
--
-- As this is intended to be an internal function, the arguments were
-- chosen to avoid repeated computation, rather than for simplicity of
-- calling this function.
delete' :: Ord key => key -- ^ The key must be present in the provided 'LRU'
        -> LRU key val -- ^ This is the 'LRU' to modify
        -> Map key (LinkedVal key val) -- ^ this is the 'Map' from the
                                       -- previous argument, but with
                                       -- the key already removed from
                                       -- it.  This isn't consistent
                                       -- yet, as it still might
                                       -- contain LinkedVals with
                                       -- pointers to the removed key.
        -> LinkedVal key val -- ^ This is the 'LinkedVal' that
                             -- corresponds to the key in the passed
                             -- in LRU. It is absent from the passed
                             -- in map.
        -> LRU key val
delete' key lru cont' lv = if Map.null cont' then deleteOnly else deleteOne
    where
      -- delete the only item in the cache
      deleteOnly = lru { first = Nothing
                       , last = Nothing
                       , content = cont'
                       }

      -- delete an item that isn't the only item
      Just firstKey = first lru
      deleteOne = if firstKey == key then deleteFirst else deleteNotFirst

      -- delete the first item
      deleteFirst = lru { first = next lv
                        , content = contFirst
                        }
      Just nKey = next lv
      contFirst = adjust' (\v -> v { prev = Nothing }) nKey cont'

      -- delete an item other than the first
      Just lastKey = last lru
      deleteNotFirst = if lastKey == key then deleteLast else deleteMid

      -- delete the last item
      deleteLast = lru { last = prev lv
                       , content = contLast
                       }
      Just pKey = prev lv
      contLast = adjust' (\v -> v { next = Nothing}) pKey cont'

      -- delete an item in the middle
      deleteMid = lru { content = contMid }
      contMid = adjust' (\v -> v { next = next lv }) pKey .
                adjust' (\v -> v { prev = prev lv }) nKey $
                cont'

-- | Internal function.  This is very similar to 'Map.adjust', with
-- two major differences.  First, it's strict in the application of
-- the function, which is a huge win when working with this structure.
--
-- Second, it requires that the key be present in order to work.  If
-- the key isn't present, 'undefined' will be inserted into the 'Map',
-- which will cause problems later.
adjust' :: Ord k => (a -> a) -> k -> Map k a -> Map k a
adjust' f k m = Map.insertWith' (\_ o -> f o) k undefined m

-- | Internal function.  This checks the three structural invariants
-- of the LRU cache structure:
--
-- 1. The cache's size does not exceed the specified max size.
--
-- 2. The linked list through the nodes is consistent in both directions.
--
-- 3. The linked list contains the same number of nodes as the cache.
valid :: Ord key => LRU key val -> Bool
valid lru = size lru <= maxSize lru &&
            reverse orderedKeys == reverseKeys &&
            size lru == length orderedKeys
    where contents = content lru
          orderedKeys = traverse next . first $ lru
          traverse _ Nothing = []
          traverse f (Just k) = let Just k' = Map.lookup k contents
                                in k : (traverse f . f $ k')
          reverseKeys = traverse prev . last $ lru
