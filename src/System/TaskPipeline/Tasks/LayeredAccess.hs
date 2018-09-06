{-# LANGUAGE Arrows                     #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# OPTIONS_GHC -Wall #-}

-- | This module provides some utilities for when the pipeline needs to access
-- several files organized in layers for each location in the 'LocationTree'
module System.TaskPipeline.Tasks.LayeredAccess
  ( layeredAccessTask
  , layeredAccessTask'
  , loadLayeredHashMaps
  , loadLayeredInput
  ) where

import           Prelude                      hiding (id, (.))

import           Control.Lens
import           Data.Hashable
import qualified Data.HashMap.Strict          as HM
import           Data.HumanSerializable
import           Data.Locations
import           Data.Locations.LocationTree  (LocationTreePathItem)
import           System.TaskPipeline.ATask
import           System.TaskPipeline.Resource


-- | Accesses each layer mapped to the required file and combines the result of
-- each access.
layeredAccessTask
  :: (LocationMonad m, Monoid o)
  => [LocationTreePathItem]   -- ^ Folder path
  -> LTPIAndSubtree SerialMethod  -- ^ File in folder
  -> String  -- ^ A name for the task (for the error message if wanted
             -- SerialMethod isn't supported)
  -> (SerialMethod -> Maybe (i -> Loc -> m o))
      -- ^ If the 'SerialMethod' is accepted, this function should return @Just
      -- f@, where @f@ is a function taking the input @i@ of the task, the 'Loc'
      -- where it should read/write, and that should perform the access and
      -- return a result @o@. This function will be called once per layer, and
      -- the results of each called will be combined since @o@ must be a
      -- 'Monoid'.
  -> ATask m PipelineResource i o
layeredAccessTask path fname taskName f =
  layeredAccessTask' path (PRscSerialMethod <$> fname) taskName f

-- | A slightly lower-level version of 'layeredAccessTask'. The file to access
-- should be tagged with a PipelineResource, not with a SerialMethod. That
-- permits for instance that the file is by default bound to @PRscVirtualFile
-- Nothing@ (which will correspond to `null` in the yaml config file)
layeredAccessTask'
  :: (LocationMonad m, Monoid o)
  => [LocationTreePathItem]   -- ^ Folder path
  -> LTPIAndSubtree UnboundPipelineResource  -- ^ File in folder
  -> String  -- ^ A name for the task (for the error message if wanted
             -- SerialMethod isn't supported)
  -> (SerialMethod -> Maybe (i -> Loc -> m o))
      -- ^ If the 'SerialMethod' is accepted, this function should return @Just
      -- f@, where @f@ is a function taking the input @i@ of the task, the 'Loc'
      -- where it should read/write, and that should perform the access and
      -- return a result @o@. This function will be called once per layer, and
      -- the results of each called will be combined since @o@ must be a
      -- 'Monoid'.
  -> ATask m PipelineResource i o
layeredAccessTask' path fname taskName f =
  liftToATask path (Identity fname) taskName $
    \i (Identity layers) ->
      case layers of
        PRscVirtualFile l -> mconcat <$>
          mapM (access i) (l^..locLayers)
        PRscNothing -> return mempty
        _ -> throwM $ TaskRunError $
          taskName ++ ": Unsupported pipeline resource to load.\
                      \ Only file paths or 'null' can be used"
  where
    access input (loc, ser) =
      case f ser of
        Nothing -> throwM $ TaskRunError $
          taskName ++ ": When accessing " ++ show loc' ++ ", " ++
          show ser ++ " serialization method not supported."
        Just f' -> f' input loc'
      where loc' = addExtToLocIfMissing loc ser

-- | A special version of 'layeredAccessTask' for loading files when you don't
-- have a readily available Monoid instance for combining the results. Tries to
-- load data from location layers bound to a single location in a
-- 'LocationTree'. The type read in each layer is 'a', and from that type we
-- extract a type 'b' which we will accumulate throughout the layers. See
-- 'liftToATask' for more information
loadLayeredInput
  :: (LocationMonad m, OfHuman a)
  => [LocationTreePathItem]       -- ^ The path of the file's folder in the
                                  -- 'LocationTree'
  -> LTPIAndSubtree SerialMethod  -- ^ The file in the 'LocationTree'
  -> String                       -- ^ The task name
  -> (b -> b -> b)                -- ^ How to merge the data extracted from each
                                  -- layer
  -> ATask m PipelineResource (a -> b, Maybe b) (Maybe b)
                         -- ^ The resulting task. Its input is the function
                         -- telling how to extract 'b' from 'a' and a possible
                         -- initial value for 'b'.
loadLayeredInput path fname taskName mergeLayersFn =
  liftToATask path (Identity $ PRscSerialMethod <$> fname) taskName go
  where
    go (fromLayer, mbAccInit) (Identity r) = load r
      where
        load PRscNothing = return mbAccInit
        load (PRscVirtualFile layers) = Just . foldLayers <$>
          mapM loadLayer (layers^..locLayers)
        load _ = throwM $ TaskRunError $
          taskName ++ ": Unsupported pipeline resource to load model from. Only file paths can be used"
        foldLayers = case mbAccInit of
          Nothing -> foldl1 mergeLayersFn
          Just x  -> foldl mergeLayersFn x
        loadLayer (loc, serMeth) = fromLayer <$> loadFromLoc
                                   (addExtToLocIfMissing loc serMeth)
          -- TODO: Give serMeth to loadFromLoc

-- | A version of 'layeredAccessTask' only for reading files. The data read in
-- each file must be convertible to a HashMap. 'loadLayeredHashMaps' uses the
-- 'HM.union' function to override each layer with the next layer.
loadLayeredHashMaps
  :: (Hashable k, Eq k, OfHuman a, LocationMonad m)
  => [LocationTreePathItem]      -- ^ The path of the file's folder in the
                                 -- 'LocationTree'
  -> LTPIAndSubtree SerialMethod -- ^ The file in the location tree to which the
                                 -- layers should be bound
  -> String                      -- ^ The task name
  -> (Lens' b (HM.HashMap k v))  -- ^ Where to find the hashmap in task input
  -> (b -> a -> HM.HashMap k v)  -- ^ Where to find the hashmap in each layer
  -> Bool                        -- ^ Should we use the hashmap from the input
                                 -- as the base layer or completely replace it?
  -> ATask m PipelineResource b b
loadLayeredHashMaps path fname taskName inputLens toHM useInputAsBase = proc input -> do
  let initAcc = if useInputAsBase
                then Just $ input^.inputLens
                else Nothing
  res <- loadLayeredInput path fname taskName (flip HM.union) -< (toHM input, initAcc)
  returnA -< case res of
    Just x  -> input & inputLens .~ x
    Nothing -> input