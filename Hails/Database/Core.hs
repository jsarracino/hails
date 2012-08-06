{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE ConstraintKinds,
             FlexibleContexts,
             DeriveDataTypeable #-}

{- |


-}

module Hails.Database.Core (
  -- * Collection
    CollectionName
  , CollectionSet
  , Collection, colName, colLabel, colClearance, colPolicy
  , collection, collectionP
  -- * Database
  , DatabaseName
  , Database, databaseName, databaseLabel, databaseCollections
  , database
  , associateCollection, associateCollectionP
  -- * Policies
  , CollectionPolicy(..)
  , FieldPolicy(..)
  , isSearchableField
  , searchableFields
  -- ** Applying policies
  , applyCollectionPolicyP
  -- ** Policy errors
  , PolicyError(..)
  -- * Labeled documents
  , LabeledHsonDocument 
  ) where

import qualified Data.List as List
import qualified Data.Set as Set
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Traversable as T
import           Data.Maybe
import           Data.Typeable

import           Control.Monad
import           Control.Exception (Exception(..))

import           LIO
import           LIO.DCLabel

import           Hails.Data.Hson
import           Hails.Data.Hson.TCB
import           Hails.PolicyModule.TCB
import           Hails.Database.TCB

--
-- Collection
--

-- | Create a 'Collection' given a name, label, clearance, and policy.
-- The supplied collection label and clearance must be above the current
-- label and below the current clearance as enforced by 'guardAlloc'.
collection :: MonadDC m
           => CollectionName  -- ^ Collection name
           -> DCLabel         -- ^ Collection label
           -> DCLabel         -- ^ Collection clearance
           -> CollectionPolicy-- ^ Collection policy
           -> m Collection
collection = collectionP noPriv

-- | Same as 'collection', but uses privileges when comparing the
-- supplied collection label and clearance with the current label and
-- clearance.
collectionP :: MonadDC m 
            => DCPriv           -- ^ Privileges
            -> CollectionName   -- ^ Collection name
            -> DCLabel          -- ^ Collection label
            -> DCLabel          -- ^ Collection clearance
            -> CollectionPolicy -- ^ Collection policy
            -> m Collection
collectionP p n l c pol = do
  guardAllocP p l
  guardAllocP p c
  return $ collectionTCB n l c pol

--
-- Database
--

-- | Given a policy module configuration, the label of the database and
-- label on collection set create the policy module's database.  Note
-- that the label of the database and collection set must be above the
-- current label (modulo the policy module's privileges) and below the
-- current clearance as imposed by 'guardAllocP'.
database :: MonadDC m 
         => PolicyModuleConf  -- ^ Policy module configuration
         -> DCLabel           -- ^ Label of database
         -> DCLabel           -- ^ Label of collection set
         -> m Database
database conf ldb lcoll = do
  guardAllocP p ldb
  cs <- labelP p lcoll Set.empty
  return $ databaseTCB n ldb cs
   where n = policyModuleDBName conf
         p = policyModulePriv conf

-- | Given a newly created collection and an existing database,
-- associate the collection with the database. To do so, the current
-- computation must be able to modify the database's collection set.
-- Specifically, the current label must equal to the collection set's
-- label as specified by the policy module. This is enforced by
-- 'guardWrite'.
associateCollection :: MonadDC m
                    => Collection  -- ^ New collection
                    -> Database    -- ^ Existing database
                    -> m Database  -- ^ New database
associateCollection = associateCollectionP noPriv

-- | Same as 'associateCollection', but uses privileges when
-- performing label comparisons and raising the current label.
associateCollectionP :: MonadDC m
                     => DCPriv      -- ^ Privileges
                     -> Collection  -- ^ New collection
                     -> Database    -- ^ Existing database
                     -> m Database  -- ^ New database
associateCollectionP p c db = do
  guardWriteP p $ labelOf (databaseCollections db)
  return $ associateCollectionTCB c db

--
-- Policies
--

-- | Returns 'True' if the field policy is a 'SearchableField'.
isSearchableField :: FieldPolicy -> Bool
isSearchableField SearchableField = True
isSearchableField _ = False

-- | Get the list of names corresponding to 'SearchableField's.
searchableFields :: CollectionPolicy -> [FieldName]
searchableFields policy =
  Map.keys $ Map.filter isSearchableField fps
  where fps = fieldLabelPolicies policy

-- | Apply a collection policy the given document, using privileges
-- when labeling the document and performing label comparisons.
-- The labeling proceeds as follows:
--
-- * If two fields have the same 'FieldName', only the first is kept.
--   This filtering is only perfomed at the top level.
--
-- * Each policy labeled value ('HsonLabeled') is labled if the policy
--   has not been applied. If the value is already labeled, then the
--   label is checked to be equivalent to that generated by the policy.
--   In both cases a failure results in 'PolicyViolation' being thrown;
--   the actual error must be hidden to retain the opaqueness of
--   'PolicyLabeled'.
--
--
--   /Note:/ For each 'FieldNamed' in the policy there /must/ be a
--   field in the document corresponding to it. Moreover its \"type\"
--   must be correct: all policy labeled values must be 'HsonLabeled'
--   values and all searchable fields must be 'HsonValue's. The @_id@
--   field is always treated as a 'SearchableField'.
--
-- * The resulting document (from the above step) is labeled according
--   to the collection policy.
--
-- The labels on 'PolicyLabeled' values and the document must be bounded
-- by the current label and clearance as imposed by 'guardAllocP'.
-- Additionally, these labels must flow to the label of the collection
-- clearance. (Of course, in both cases privileges are used to allow for
-- more permissive flows.)
applyCollectionPolicyP :: MonadDC m
                       => DCPriv        -- ^ Privileges
                       -> Collection    -- ^ Collection and policies
                       -> HsonDocument  -- ^ Document to apply policies to
                       -> m (LabeledHsonDocument)
applyCollectionPolicyP p col doc0 = liftLIO $ do
  let doc1 = List.nubBy (\f1 f2 -> fieldName f1 == fieldName f2) doc0
  typeCheckDocument fieldPolicies doc1
  withClearance (colClearance col) $ do
    -- Apply fied policies:
    doc2 <- T.for doc1 $ \f@(HsonField n v) ->
      case v of
        (HsonValue _) -> return f
        (HsonLabeled pl) -> do
          -- NOTE: typeCheckDocument MUST be run before this:
          let (FieldPolicy fieldPolicy) = fieldPolicies Map.! n
              l = fieldPolicy doc1
          case pl of
            (NeedPolicyTCB bv) -> do
              lbv <- labelP p l bv `onException` throwLIO PolicyViolation
              return (n -: hasPolicy lbv)
            (HasPolicyTCB lbv) -> do 
              unless (labelOf lbv == l) $ throwLIO PolicyViolation
              return f
    -- Apply document policy:
    labelP p (docPolicy doc2) doc2
  where docPolicy     = documentLabelPolicy . colPolicy $ col
        fieldPolicies = fieldLabelPolicies  . colPolicy $ col

-- | This function \"type-checks\" a document against a set of policies.
-- Specifically, it checks that the set of policy labeled values is the
-- same between the policy and document, and searchable fields are not
-- policy labeled.
typeCheckDocument :: Map FieldName FieldPolicy -> HsonDocument -> DC ()
typeCheckDocument ps doc = do
  -- Check that every policy-named value is well-typed
  void $ T.for psList $ \(k,v) -> do
    let mv' = look k doc
        v' = fromJust mv'
    unless (isJust mv') $ throwLIO $ TypeError $ 
      "Missing field with name " ++ show k
    case v of
      SearchableField -> isHsonValue   k v'
      FieldPolicy _   -> isHsonLabeled k v'
  -- Check that no policy-labeled values not named in the policy
  -- exist:
  let doc' = exclude (map fst psList) doc
  unless (isBsonDoc doc') $ throwLIO $ TypeError $
     "Fields " ++ show (map fieldName doc') ++ " should NOT be policy labeled."
        where psList = Map.toList ps
              isHsonValue _ (HsonValue _) = return ()
              isHsonValue k _ = throwLIO $ TypeError $
                show k ++ " should NOT be policy labeled"
              isHsonLabeled _ (HsonLabeled _) = return ()
              isHsonLabeled k _ = throwLIO $ TypeError $
                show k ++ " should be policy labeled"


--
-- Policy error
--

-- | A document policy error.
data PolicyError = TypeError String -- ^ Document is not \"well-typed\"
                 | PolicyViolation  -- ^ Policy has been violated
                 deriving (Show, Typeable)

instance Exception PolicyError

--
-- Labeled documents
--
-- | A labeled 'HsonDocument'.
type LabeledHsonDocument = DCLabeled HsonDocument
