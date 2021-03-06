{-# LANGUAGE Arrows                     #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeSynonymInstances       #-}

-- | This module exposes the 'PTask' arrow along with some low-level functions
-- to create and run a 'PTask'.

module System.TaskPipeline.PTask.Internal
  ( PTask(..)
  , PTaskState
  , RunnableTask
  , FunflowRunConfig(..)
  , CanRunPTask
  , FunflowOpts(..)
  , ptrsKatipContext
  , ptrsKatipNamespace
  , ptrsFunflowRunConfig
  , ptrsDataAccessTree
  , splitTask
  , runnableTaskReaderState
  , makeTask
  , makeTask'
  , modifyingRuntimeState
  , withRunnableState
  , withRunnableState'
  , execRunnableTask
  , execRunnableTaskFromTaskState
  , runnableWithoutReqs
  , withTaskState
  , identityVar
  ) where

import           Prelude                                     hiding (id, (.))

import           Control.Arrow
import           Control.Arrow.AppArrow
import           Control.Arrow.Async
import           Control.Arrow.Free                          (ArrowError)
import           Control.Category
import           Control.Funflow
import qualified Control.Funflow.ContentStore                as CS
import           Control.Funflow.External.Coordinator
import           Control.Funflow.External.Coordinator.SQLite
import qualified Control.Funflow.RemoteCache                 as Remote
import           Control.Lens
import           Control.Monad.Trans
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State
import           Control.Monad.Trans.Writer
import           Data.Default
import           Data.Locations.Accessors
import           Data.Locations.FunflowRemoteCache
import           Data.Locations.LocationTree
import           Data.Locations.LogAndErrors
import           Katip
import           Katip.Core                                  (Namespace)
import           Path
import           System.TaskPipeline.PorcupineTree


-- | PTask functions like mappingOverStream make necessary to recursively run
-- some flows. Until we find a better solution than to run flows in flows, this
-- is how we do it. These are the arguments to
-- Control.Funflow.Exec.Simple.runFlowEx
data FunflowRunConfig m = forall c rc. (Coordinator c, Remote.Cacher m rc) => FunflowRunConfig
  { _ffrcCoordinator       :: !c
  , _ffrcCoordinatorConfig :: !(Config c)
  , _ffrcContentStore      :: !CS.ContentStore
  , _ffrcFlowIdentity      :: !(Maybe Int)
  , _ffrcRemoteCache       :: !rc
  }

-- | This is the state that will be shared by the whole PTask pipeline once it
-- starts running.
data PTaskState m = PTaskState
  { _ptrsKatipContext     :: !LogContexts
  , _ptrsKatipNamespace   :: !Namespace
  , _ptrsFunflowRunConfig :: !(FunflowRunConfig m)
  , _ptrsDataAccessTree   :: !(DataAccessTree m) }

makeLenses ''PTaskState

-- | The part of a 'PTask' that will be ran once the whole pipeline is composed
-- and the tree of requirements has been bound to physical locations. Is is
-- important to note that while both 'PTask' and 'RunnableTask' are Arrows,
-- only 'RunnableTask' is an ArrowChoice.
type RunnableTask m =
  AppArrow
    (Reader (PTaskState m)) -- The reader layer contains the mapped
                                  -- tree. Will be used only as an applicative.
    (Flow (InnerEffect m) SomeException)

-- | The constraints that must be satisfied by the base monad m so that a @PTask
-- m@ can be run
type CanRunPTask m = (MonadBaseControl IO m, LogMask m)

-- | A task is an Arrow than turns @a@ into @b@. It runs in some monad @m@.
-- Each 'PTask' will expose its requirements in terms of resource it wants to
-- access in the form of a virtual tree (implemented as a 'LocationTree' of
-- 'VirtualFile's). These trees of requirements are aggregated when the tasks
-- are combined with each other, so once the full pipeline has been composed
-- (through Arrow composition), its 'pTaskVirtualTree' will contain the
-- complete requirements of the pipeline.
newtype PTask m a b = PTask
  (AppArrow
    (Writer VirtualTree)  -- The writer layer accumulates the requirements. It will
                      -- be used only as an applicative.
    (RunnableTask m)
    a b)
  deriving (Category, Arrow, ArrowError SomeException, Functor, Applicative)
  -- PTask doesn't instanciate ArrowChoice. That's intentional, even if an
  -- instance could be automatically derived. The ArrowChoice implementation for
  -- `AppArrow (Writer x) arr` isn't sane for PTasks, as the monoid state (the
  -- PTask requirements) will be accumulated by (|||) in a way that's
  -- indistiguishable from (>>>), that is to say that doesn't differentiate
  -- VirtualFiles that _will_ be used from those that _may_ be used. Maybe in
  -- the future we will implement ArrowChoice/ArrowPlus/ArrowZero in a saner way (it
  -- should even be necessary if we want to implement serialization methods with
  -- PTask themselves, and have serial method selection based on file format or
  -- mapping metadata), but in that case it's necessary that the pipeline
  -- configuration file reflects this "either-or" nature of VirtualFiles.

flowToPTask :: Flow (InnerEffect m) SomeException a b -> PTask m a b
flowToPTask = PTask . appArrow . appArrow

-- | The type of effects we can run. The reader layer is executed by 'wrap',
-- this is why it doesn't appear in the Flow part of the 'RunnableTask' type.
type OuterEffect m =
  AsyncA (ReaderT (PTaskState m) m)

-- | The effects ran inside the flow have to handle some dynamic modifications
-- of the state (for instance from task inputs) that have to be applied to each
-- state passed to 'wrap'. We store these modifications as a stack of functions.
type InnerEffect m =
  AsyncA (StateT [PTaskState m -> PTaskState m] m)

instance (KatipContext m)
      => ArrowFlow (OuterEffect m) SomeException (PTask m) where
  step' props f = flowToPTask $ step' props f
  stepIO' props f = flowToPTask $ stepIO' props f
  external f = flowToPTask $ external f
  external' props f = flowToPTask $ external' props f
  -- wrap' transmits the Reader state of the PTask down to the flow:
  wrap' props (AsyncA rdrAct) = runnableWithoutReqs $
    withRunnableState' props $ \outerState input ->
      runReaderT (rdrAct input) outerState
  putInStore f = flowToPTask $ putInStore f
  getFromStore f = flowToPTask $ getFromStore f
  internalManipulateStore f = flowToPTask $ internalManipulateStore f

withOuterState
  :: (ArrowFlow (AsyncA m) ex arr)
  => Properties a b
  -> (t -> a -> m b)
  -> AppArrow (Reader t) arr a b
withOuterState props f =
  AppArrow $ reader $ \outerState ->
    wrap' props $ AsyncA $ \input ->
      f outerState input

-- | The task will be executed with a new state modifier pushed on the modifiers
-- stack.
modifyingRuntimeState
  :: (Monad m)
  => (a -> PTaskState m -> PTaskState m)
  -> (a -> a')
  -> RunnableTask m a' b
  -> RunnableTask m a b
modifyingRuntimeState alterState alterInput ar = pushState >>> ar >>> popState
  where
    pushState =
      withOuterState def $ \_ x -> do
        modify (alterState x :)
        return (alterInput x)
    popState =
      withOuterState def $ \_ x -> do
        modify popMod
        return x
    popMod [] = error $
      "modifyingRunnableState: Modifiers list shouldn't be empty!"
    popMod (_:ms) = ms

-- | At the 'RunnableTask' level, access the reader state and run an action
withRunnableState' :: (KatipContext m)
                   => Properties a b -> (PTaskState m -> a -> m b) -> RunnableTask m a b
withRunnableState' props f = withOuterState props $ \outerState input -> do
  mods <- get
  let ptrs = foldr ($) outerState mods
  lift $
    localKatipContext (const $ _ptrsKatipContext ptrs) $
      localKatipNamespace (const $ _ptrsKatipNamespace ptrs) $
        f ptrs input

-- | 'withRunnableState'' without caching.
withRunnableState :: (KatipContext m)
                  => (PTaskState m -> a -> m b) -> RunnableTask m a b
withRunnableState = withRunnableState' def

-- | Wraps a 'RunnableTask' into a 'PTask' that declares no requirements
runnableWithoutReqs :: RunnableTask m a b -> PTask m a b
runnableWithoutReqs = PTask . appArrow

-- | An Iso to the requirements and the runnable part of a 'PTask'
splitTask :: Iso (PTask m a b) (PTask m a' b')
                     (VirtualTree, RunnableTask m a b)
                     (VirtualTree, RunnableTask m a' b')
splitTask = iso to_ from_
  where
    to_ (PTask (AppArrow wrtrAct)) = swap $ runWriter wrtrAct
    from_ = PTask . AppArrow . writer . swap
    swap (a,b) = (b,a)

-- | Permits to apply a function to the Reader state of a 'RunnableTask' when
-- in runs.
runnableTaskReaderState :: Setter' (RunnableTask m a b) (PTaskState m)
runnableTaskReaderState = lens unAppArrow (const AppArrow) . setting local

-- | Makes a task from a tree of requirements and a function. The 'Properties'
-- indicate whether we can cache this task.
makeTask' :: (KatipContext m)
           => Properties a b
           -> LocationTree VirtualFileNode
           -> (DataAccessTree m -> a -> m b)
           -> PTask m a b
makeTask' props tree f =
  (tree, withRunnableState' props (f . _ptrsDataAccessTree)) ^. from splitTask

-- | Makes a task from a tree of requirements and a function. This is the entry
-- point to PTasks
makeTask :: (KatipContext m)
          => LocationTree VirtualFileNode
          -> (DataAccessTree m -> a -> m b)
          -> PTask m a b
makeTask = makeTask' def

data FunflowOpts m = FunflowOpts
  { storePath      :: FilePath
  , coordPath      :: FilePath
  , flowIdentity   :: Maybe Int
  , remoteCacheLoc :: Maybe (SomeLoc m) }
  deriving (Show)

withFunflowRunConfig
  :: (LogMask m)
  => FunflowOpts m
  -> (FunflowRunConfig m -> m r)
  -> m r
withFunflowRunConfig ffopts f = do
  storePath' <- parseAbsDir $ storePath ffopts
  coordPath' <- parseAbsDir $ coordPath ffopts
  let cacher = locationCacher $ remoteCacheLoc ffopts
  CS.withStore storePath' (\store ->
    f $ FunflowRunConfig SQLite coordPath' store (flowIdentity ffopts) cacher)

-- | Given a 'KatipContext' and a 'DataAccessTree', gets the initial state to
-- give to 'execRunnableTask'
withTaskState :: (LogMask m)
               => FunflowOpts m
               -> DataAccessTree m
               -> (PTaskState m -> m r) -> m r
withTaskState ffPaths tree f =
  withFunflowRunConfig ffPaths $ \ffconfig -> do
    ctx <- getKatipContext
    ns  <- getKatipNamespace
    f $ PTaskState ctx ns ffconfig tree

-- | Runs a 'RunnableTask' given its state
execRunnableTaskFromTaskState
  :: (CanRunPTask m)
  => RunnableTask m a b -> PTaskState m -> a -> m b
execRunnableTaskFromTaskState
  (AppArrow act)
  st@PTaskState{_ptrsFunflowRunConfig=FunflowRunConfig{..}}
  input =
  flip evalStateT [] $
    runFlowEx _ffrcCoordinator _ffrcCoordinatorConfig
              _ffrcContentStore (LiftCacher _ffrcRemoteCache) id _ffrcFlowIdentity
              (runReader act st)
              input

identityVar :: String
identityVar = "FUNFLOW_IDENTITY"

-- | Runs a 'RunnableTask' from a 'DataAccessTree'
execRunnableTask
  :: (LogMask m, MonadBaseControl IO m)
  => FunflowOpts m -> DataAccessTree m -> RunnableTask m a b -> a -> m b
execRunnableTask ffopts dataTree runnableTask input = do
  -- Katip context is required anyway due to withTaskState:
  $(logTM) NoticeS $ logStr $ case flowIdentity ffopts of
      Just i -> "Using funflow store at '" ++ storePath ffopts ++ "' with identity "
                ++ show i ++ "." ++
                (case remoteCacheLoc ffopts of
                   Just l -> "Using remote cache at " ++ show l
                   _      -> "")
      Nothing -> identityVar ++ " not specified. The cache will not be used."
  withTaskState ffopts dataTree $ \initState ->
    execRunnableTaskFromTaskState runnableTask initState input
