{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module System.TaskPipeline.Tasks.Repetition
  ( STask, ISTask, OSTask
  , mappingOverStream
  , mappingOverStream_
  , repeatedlyWriteData
  , repeatedlyLoadData
  , repeatedlyLoadData'
  , listToStreamTask, runStreamTask, streamToListTask
  , Typeable
  ) where

import           Control.Lens                            hiding ((:>), (.=))
import           Control.Monad
import           Data.Aeson
import qualified Data.HashMap.Strict                     as HM
import           Data.Locations
import qualified Data.Text                               as T
import           Data.Typeable
import           Katip
import           Prelude                                 hiding ((.))
import           Streaming                               (Of (..), Stream)
import qualified Streaming.Prelude                       as S
import qualified System.FilePath                         as P
import           System.TaskPipeline.ATask
import           System.TaskPipeline.ResourceTree
import           System.TaskPipeline.Tasks.LayeredAccess


-- * Logging context for repeated tasks

data TaskRepetitionContext = TRC
  { _repetitionKey     :: RepetitionKey
  , _repetitionKeyVal  :: T.Text
  , _repetitionKeyVerb :: Verbosity }

instance ToJSON TaskRepetitionContext where
  toJSON (TRC (RepetitionKey k) i _) = object [ k .= i ]
instance ToObject TaskRepetitionContext
instance LogItem TaskRepetitionContext where
  payloadKeys v (TRC _ _ v') | v >= v' = AllKeys
                             | otherwise = SomeKeys []

-- * Type aliases for tasks over streams

-- | An ATask mapping a action over a Stream, transforming @a@'s into
-- @b@'s. Each element in the stream should be associated to an identifier.
type STask m i a b r =
  ATask m (ResourceTreeNode m)
        (Stream (Of (i, a)) m r)
        (Stream (Of (i, b)) m r)

-- | An 'ATask' that consumes an Input Stream and just returns its result.
type ISTask m i a r =
  ATask m (ResourceTreeNode m)
        (Stream (Of (i, a)) m r)
        r

-- | An 'ATask' that emits an Output Stream.
type OSTask m i a b =
  ATask m (ResourceTreeNode m)
        a
        (Stream (Of (i, b)) m ())

-- * Running tasks over streams

-- | Turns a task into something that will be repeated once per each item in its
-- input. This is done by transforming VirtualFile accessed by the tasks to add
-- a 'RepetitionKey' to it, indicating that its final file name should be
-- modified by adding an identifier to it just before reading it or writing it.
-- So each loop actually accesses different locations in the end.
--
-- Calls to 'mappingOverStream' can be nested, this way the underlying VirtualFiles
-- will have one 'RepetitionKey' per loop (from outermost loop to innermost).
--
-- Note: The repeated task has to be executed on the first element of the stream
-- before the next task can consume the resulting stream. This next task will
-- receive as resource tree the one returned by this first iteration.
mappingOverStream
  :: forall m i a b r.
     (KatipContext m, Show i)
  => RepetitionKey                 -- ^ A key to indicate which repetition we're
                                   -- at. Used by the logger and the read/write
                                   -- code.
  -> Maybe Verbosity               -- ^ The minimal vebosity level at which to
                                   -- display the logger context. (Nothing if we
                                   -- don't want to add context)
  -> ATask m (ResourceTreeNode m) a b  -- ^ The base task X to repeat
  -> STask m i a b r               -- ^ A task that will repeat X it for each
                                   -- input. Each input is associated to a
                                   -- identifier that will be appended to
                                   -- every Loc mapped to every leaf in the
                                   -- LocationTree given to X.
mappingOverStream repetitionKey mbVerb (ATask reqTree perform) = ATask reqTree' perform'
  where
    reqTree' = fmap addKeyToVirtualFile reqTree

    perform' (inputStream, origTree) = do
      firstElem <- S.next inputStream
      case firstElem of
        Left r -> return (return r, origTree)  -- Empty input stream
        Right (firstInput, inputStream') -> do
          (firstResult, firstOutputTree) <- performOnce origTree firstInput
          let resultStream =
                firstResult `S.cons` S.mapM (fmap fst . performOnce origTree) inputStream'
          return (resultStream, firstOutputTree)

    addKeyToVirtualFile (VirtualFileNode vf) =
      VirtualFileNode $ vf & vfileSerials . serialsRepetitionKeys %~ (repetitionKey:)
    addKeyToVirtualFile emptyNode = emptyNode

    addKeyValToDataAccess :: T.Text -> DataAccessNode m -> DataAccessNode m
    addKeyValToDataAccess val (DataAccessNode l fn) =
      DataAccessNode l $ fn . HM.insert repetitionKey val
    addKeyValToDataAccess _ emptyNode = emptyNode

    performOnce origTree (val, inp) = case mbVerb of
      Nothing   -> go
      Just verb -> katipAddContext (TRC repetitionKey val' verb) go
      where
        val' = T.pack $ show val
        go = do
          (res, tree) <- perform ( inp, fmap (fmap (addKeyValToDataAccess val')) origTree )
          return ((val, res), tree)

    -- updateTree ident =
    --   over (traversed . rscAccessed . pRscVirtualFile . locLayers . _1)
    --        (updateLoc ident)
    -- -- We change the filename of every loc bound to a leaf, to add the
    -- -- identifier to it
    -- updateLoc ident loc = dir </> (fname ++ "-" ++ show ident) <.> T.unpack ext
    --   where
    --     dir = takeDirectory loc
    --     fname = P.dropExtension $ P.takeFileName (loc ^. locPath)
    --     ext = loc ^. locExt

-- | See 'mappingOverStream'. Just runs the resulting stream and returns its end
-- result.
mappingOverStream_
  :: (KatipContext m, Show i)
  => RepetitionKey
  -> Maybe Verbosity
  -> ATask m (ResourceTreeNode m) a b
  -> ISTask m i a r
mappingOverStream_ k v t =
  mappingOverStream k v t >>> runStreamTask

-- | Writes to the same virtual file each element in the input stream, but
-- changing each time the value associated to a repetition key (so the physical
-- file will be different each time). Returns the result of the input stream.
repeatedlyWriteData
  :: (LocationMonad m, KatipContext m, Typeable a, Show i)
  => RepetitionKey
  -> VirtualFile a ignored -- ^ A 'DataSink'
  -> ISTask m i a r
repeatedlyWriteData rkey vf =
  mappingOverStream_ rkey (Just V1) $ writeData vf

-- | Reads from the same virtual file for each index in the input stream, but
-- changing each time the value associated to a repetition key (so the physical
-- file will be different each time).
repeatedlyLoadData
  :: (LocationMonad m, KatipContext m, Typeable b, Monoid b, Show i)
  => RepetitionKey
  -> VirtualFile ignored b
  -> OSTask m i (Stream (Of i) m r) b
repeatedlyLoadData rkey vf =
  arr (fmap (const ()) . S.map (,()))
  >>>
  mappingOverStream rkey (Just V1) (loadData vf)

-- | Like 'repeatedlyLoadData', except the stream of indices to read is obtained
-- from a list whose elements can be Shown.
repeatedlyLoadData'
  :: (LocationMonad m, KatipContext m, Typeable b, Monoid b, Show i)
  => RepetitionKey
  -> VirtualFile ignore b
  -> OSTask m i [i] b
repeatedlyLoadData' rkey vf =
  arr S.each >>> repeatedlyLoadData rkey vf


-- * Helper functions to create and run streams

-- | Runs the input stream, forgets all its elements and just returns its result
runStreamTask :: (Monad m)
              => ATask m (ResourceTreeNode m)
                       (Stream (Of t) m r)
                       r
runStreamTask = unsafeLiftToATask S.effects

-- | An 'ATask' converting a list to a stream
listToStreamTask :: (Monad m)
                 => ATask m (ResourceTreeNode m)
                          [t]
                          (Stream (Of t) m ())
listToStreamTask = arr S.each

-- | An 'ATask' converting an input stream to a list. WARNING: It can cause
-- space leaks if the list is too big, as the output list will be eagerly
-- evaluated. This function is provided only for compatibility with existing
-- tasks expecting lists. Please consider switching to processing streams
-- directly. See 'S.toList' for more details.
streamToListTask :: (Monad m)
                 => ATask m (ResourceTreeNode m)
                          (Stream (Of t) m r)
                          [t]
streamToListTask = unsafeLiftToATask (S.toList_ . fmap (const ()))
