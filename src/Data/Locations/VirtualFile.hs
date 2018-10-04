{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GADTs #-}

module Data.Locations.VirtualFile
  ( LocationTreePathItem
  , SerializationMethod(..)
  , FileExt
  , BidirSerials, PureSerials, PureDeserials
  , JSONSerial(..), PlainTextSerial(..)
  , Profunctor(..)
  , VirtualFile_(..), VFMetadata(..)
  , VirtualFile, BidirVirtualFile, DataSource, DataSink
  , VirtualFileIntent(..), VirtualFileDescription(..)
  , vfileUsedByDefault, vfilePath
  , someBidirSerial, somePureSerial, somePureDeserial
  , customPureSerial, customPureDeserial, makeBidir
  , dataSource, dataSink, bidirVirtualFile
  , makeSink, makeSource
  , documentedFile, unusedByDefault
  , removeVFilePath
  , vfileStateData
  , getVirtualFileDescription
  , extractDefaultAesonValue
  ) where

import           Control.Lens
import           Data.Locations.LocationTree
import           Data.Locations.SerializationMethod
import Data.Aeson (Value, toJSON)
import           Data.Monoid                        (First (..))
import           Data.Profunctor                    (Profunctor (..))
import qualified Data.Text                          as T
import Data.Typeable
import           Data.Void
import Data.Type.Equality
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Data.Locations.Mappings (HasDefaultMappingRule(..))


-- | A virtual file in the location tree to which we can write @a@ and from
-- which we can read @b@.
data VirtualFile_ d a b = VirtualFile
  { _vfileStateData :: d
  , vfileBidirProof :: First (a :~: b)
                    -- Temporary, necessary until we can do away with docrec
                    -- conversion in the writer part of SerialsFor
  , vfileSerials    :: SerialsFor a b }

instance (HasDefaultMappingRule d) => HasDefaultMappingRule (VirtualFile_ d a b) where
  isMappedByDefault = isMappedByDefault . _vfileStateData

vfileStateData :: Lens (VirtualFile_ d a b) (VirtualFile_ d' a b) d d'
vfileStateData f vf = (\d' -> vf{_vfileStateData=d'}) <$> f (_vfileStateData vf)

instance Semigroup d => Semigroup (VirtualFile_ d a b) where
  VirtualFile d b s <> VirtualFile d' b' s' =
    VirtualFile (d<>d') (b<>b') (s<>s')
instance Monoid d => Monoid (VirtualFile_ d a b) where
  mempty = VirtualFile mempty mempty mempty

fn :: First a
fn = First Nothing

instance Profunctor (VirtualFile_ d) where
  dimap f g (VirtualFile d _ s) = VirtualFile d fn $ dimap f g s

-- | Describes how a virtual file is meant to be used
data VirtualFileIntent =
  VFForWriting | VFForReading | VFForRW | VFForCaching | VFForCLIOptions
  deriving (Show, Eq)

-- | Gives the purpose of the 'VirtualFile'. Used to document the pipeline and check
-- mappings to physical files.
data VirtualFileDescription = VirtualFileDescription
  { vfileDescIntent :: Maybe VirtualFileIntent
                        -- ^ How is the 'VirtualFile' meant to be used
  , vfileDescEmbeddableInConfig :: Bool
                        -- ^ True if the data can be read directly from the
                        -- pipeline's config file
  , vfileDescEmbeddableInOutput :: Bool
                        -- ^ True if the data can be written directly in the
                        -- pipeline's output location tree
  , vfileDescPossibleExtensions :: [FileExt]
                        -- ^ Possible extensions for the files this virtual file
                        -- can be mapped to (prefered extension is the first)
  }
  deriving (Show)

-- | Gives a 'VirtualFileDescription'. To be used on files stored in the
-- ResourceTree.
getVirtualFileDescription :: VirtualFile_ d a b -> VirtualFileDescription
getVirtualFileDescription (VirtualFile _ bidir (SerialsFor (SerialWriters toI toC toE)
                                                           (SerialReaders fromI fromC fromE)
                                                           prefExt)) =
  VirtualFileDescription intent readableFromConfig writableInOutput exts
  where
    intent
      | First (Just _) <- fromC, First (Just _) <- toC = Just VFForCLIOptions
      | HM.null fromE && HM.null toE = Nothing
      | HM.null fromE = Just VFForWriting
      | HM.null toE = Just VFForReading
      | First (Just _) <- bidir = Just VFForCaching
      | otherwise = Just VFForRW
    otherExts = HS.fromList $ HM.keys toE <> HM.keys fromE
    exts = case prefExt of
             First (Just e) -> e:(HS.toList $ HS.delete e otherExts)
             _ -> HS.toList otherExts
    typeOfAesonVal = typeOf (undefined :: Value)
    readableFromConfig = typeOfAesonVal `HM.member` fromI
    writableInOutput = typeOfAesonVal `HM.member` toI

data VFMetadata = VFMetadata
  { _vfileMD_UsedByDefault :: Bool
  , _vfileMD_Documentation :: First T.Text }

instance HasDefaultMappingRule VFMetadata where
  isMappedByDefault = _vfileMD_UsedByDefault

makeLenses ''VFMetadata

instance Semigroup VFMetadata where
  VFMetadata u d <> VFMetadata u' d' = VFMetadata (u && u') (d<>d')

-- | A VirtualFile, as declared by an application.
type VirtualFile = VirtualFile_ ([LocationTreePathItem], VFMetadata)

removeVFilePath :: VirtualFile a b -> VirtualFile_ VFMetadata a b
removeVFilePath vf = vf & vfileStateData %~ view _2

vfilePath :: VirtualFile a b -> [LocationTreePathItem]
vfilePath = view (vfileStateData . _1)

vfileUsedByDefault :: VirtualFile a b -> Bool
vfileUsedByDefault = view (vfileStateData . _2 . vfileMD_UsedByDefault)

-- | A virtual file which depending on the situation can be written or read
type BidirVirtualFile a = VirtualFile a a

-- | A virtual file that's only readable
type DataSource a = VirtualFile Void a

-- | A virtual file that's only writable
type DataSink a = VirtualFile a ()


-- | Creates a virtuel file from its virtual path and ways serialize/deserialize
-- the data. You should prefer 'dataSink' and 'dataSource' for clarity when the
-- file is meant to be readonly or writeonly.
virtualFile :: [LocationTreePathItem] -> Maybe (a :~: b) -> SerialsFor a b -> VirtualFile a b
virtualFile path refl sers =
  VirtualFile (path, VFMetadata True fn) (First refl) sers

-- | Creates a virtual file from its virtual path and ways to deserialize the
-- data.
dataSource :: [LocationTreePathItem] -> SerialsFor a b -> DataSource b
dataSource path = virtualFile path Nothing . eraseSerials

-- | Creates a virtual file from its virtual path and ways to serialize the
-- data.
dataSink :: [LocationTreePathItem] -> SerialsFor a b -> DataSink a
dataSink path = virtualFile path Nothing . eraseDeserials

-- | Like VirtualFile, except we will embed the proof that @a@ and @b@ are the same
bidirVirtualFile :: [LocationTreePathItem] -> BidirSerials a -> BidirVirtualFile a
bidirVirtualFile path sers = virtualFile path (Just Refl) sers

makeSink :: VirtualFile a b -> DataSink a
makeSink vf = vf{vfileSerials=eraseDeserials $ vfileSerials vf
                ,vfileBidirProof=fn}

makeSource :: VirtualFile a b -> DataSource b
makeSource vf = vf{vfileSerials=eraseSerials $ vfileSerials vf
                  ,vfileBidirProof=fn}


-- | Indicates that the file should be mapped to 'null' by default
unusedByDefault :: VirtualFile a b -> VirtualFile a b
unusedByDefault = vfileStateData . _2 . vfileMD_UsedByDefault .~ False

-- | Gives a documentation to the 'VirtualFile'
documentedFile :: T.Text -> VirtualFile a b -> VirtualFile a b
documentedFile doc = vfileStateData . _2 . vfileMD_Documentation .~ First (Just doc)

extractDefaultAesonValue :: VirtualFile_ d a b -> Maybe Value
extractDefaultAesonValue vf = case mbopts of
  Just (Refl, WriteToConfigFn convert, defVal) -> Just $ toJSON $ convert defVal
  _ -> Nothing
  where
        s = vfileSerials vf
        First mbopts = (,,) <$> vfileBidirProof vf
                        <*> serialWriterToConfig (serialWriters s)
                        <*> (readFromConfigDefault <$> serialReaderFromConfig (serialReaders s))
