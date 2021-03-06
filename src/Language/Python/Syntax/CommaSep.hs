{-# language LambdaCase #-}
{-# language DeriveFunctor, DeriveFoldable, DeriveTraversable #-}

{-|
Module      : Language.Python.Syntax.CommaSep
Copyright   : (C) CSIRO 2017-2018
License     : BSD3
Maintainer  : Isaac Elliott <isaace71295@gmail.com>
Stability   : experimental
Portability : non-portable
-}

module Language.Python.Syntax.CommaSep
  ( Comma (..)
  , CommaSep (..)
  , appendCommaSep, maybeToCommaSep, listToCommaSep
  , CommaSep1 (..)
  , commaSep1Head, appendCommaSep1, listToCommaSep1, listToCommaSep1'
  , CommaSep1' (..)
  , _CommaSep1'
  )
where

import Control.Lens.Getter ((^.))
import Control.Lens.Iso (Iso, iso)
import Control.Lens.Lens (lens)
import Control.Lens.Setter ((.~))
import Data.Coerce (coerce)
import Data.Function ((&))
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty(..))
import Data.Maybe (fromMaybe)
import Data.Semigroup (Semigroup(..))

import Language.Python.Syntax.Whitespace (Whitespace (Space), HasTrailingWhitespace (..))

-- | The venerable comma separator
newtype Comma =
  Comma [Whitespace]
  deriving (Eq, Show)

instance HasTrailingWhitespace Comma where
  trailingWhitespace =
    lens (\(Comma ws) -> ws) (\_ ws -> Comma ws)

-- | Items separated by commas, with optional whitespace following each comma
data CommaSep a
  = CommaSepNone
  | CommaSepOne a
  | CommaSepMany a Comma (CommaSep a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Convert a maybe to a singleton or nullary 'CommaSep'
maybeToCommaSep :: Maybe a -> CommaSep a
maybeToCommaSep = maybe CommaSepNone CommaSepOne

-- | Convert a list to a 'CommaSep'
--
-- Anywhere where whitespace is ambiguous, this function puts a single space
listToCommaSep :: [a] -> CommaSep a
listToCommaSep [] = CommaSepNone
listToCommaSep [a] = CommaSepOne a
listToCommaSep (a:as) = CommaSepMany a (Comma [Space]) $ listToCommaSep as

appendCommaSep :: [Whitespace] -> CommaSep a -> CommaSep a -> CommaSep a
appendCommaSep _  CommaSepNone b = b
appendCommaSep _  (CommaSepOne a) CommaSepNone = CommaSepOne a
appendCommaSep ws (CommaSepOne a) (CommaSepOne b) = CommaSepMany a (Comma ws) (CommaSepOne b)
appendCommaSep ws (CommaSepOne a) (CommaSepMany b c cs) = CommaSepMany a (Comma ws) (CommaSepMany b c cs)
appendCommaSep ws (CommaSepMany a c cs) b = CommaSepMany a c (appendCommaSep ws cs b)

instance Semigroup (CommaSep a) where
  (<>) = appendCommaSep [Space]

instance Monoid (CommaSep a) where
  mempty  = CommaSepNone
  mappend = (<>)

-- | Non-empty 'CommaSep'
data CommaSep1 a
  = CommaSepOne1 a
  | CommaSepMany1 a Comma (CommaSep1 a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

commaSep1Head :: CommaSep1 a -> a
commaSep1Head (CommaSepOne1 a) = a
commaSep1Head (CommaSepMany1 a _ _) = a

appendCommaSep1 :: [Whitespace] -> CommaSep1 a -> CommaSep1 a -> CommaSep1 a
appendCommaSep1 ws a b =
  CommaSepMany1
    (case a of; CommaSepOne1 x -> x;  CommaSepMany1 x _ _  -> x)
    (case a of; CommaSepOne1 _ -> Comma ws; CommaSepMany1 _ ws' _ -> ws')
    (case a of; CommaSepOne1 _ -> b;  CommaSepMany1 _ _ x  -> x <> b)

instance Semigroup (CommaSep1 a) where
  (<>) = appendCommaSep1 [Space]

instance HasTrailingWhitespace s => HasTrailingWhitespace (CommaSep1 s) where
  trailingWhitespace =
    lens
      (\case
         CommaSepOne1 a -> a ^. trailingWhitespace
         CommaSepMany1 _ _ a -> a ^. trailingWhitespace)
      (\cs ws ->
         case cs of
           CommaSepOne1 a ->
             CommaSepOne1 (a & trailingWhitespace .~ ws)
           CommaSepMany1 a b c -> CommaSepMany1 (coerce a) b (c & trailingWhitespace .~ ws))

-- | Convert a 'NonEmpty' to a 'CommaSep1'
--
-- Anywhere where whitespace is ambiguous, this function puts a single space
listToCommaSep1 :: NonEmpty a -> CommaSep1 a
listToCommaSep1 (a :| as) = go (a:as)
  where
    go [] = error "impossible"
    go [x] = CommaSepOne1 x
    go (x:xs) = CommaSepMany1 x (Comma [Space]) $ go xs

-- | Non-empty 'CommaSep', optionally terminated by a comma
-- Assumes that the contents consumes trailing whitespace
data CommaSep1' a
  = CommaSepOne1' a (Maybe Comma)
  | CommaSepMany1' a Comma (CommaSep1' a)
  deriving (Eq, Show, Functor, Foldable, Traversable)

_CommaSep1'
  :: Iso
       (a, [(Comma, a)], Maybe Comma)
       (b, [(Comma, b)], Maybe Comma)
       (CommaSep1' a)
       (CommaSep1' b)
_CommaSep1' = iso toCs fromCs
  where
    toCs (a, [], b) = CommaSepOne1' a b
    toCs (a, (b, c) : bs, d) = CommaSepMany1' a b $ toCs (c, bs, d)

    fromCs (CommaSepOne1' a b) = (a, [], b)
    fromCs (CommaSepMany1' a b c) =
      let
        (d, e, f) = fromCs c
      in
        (a, (b, d) : e, f)

listToCommaSep1' :: [a] -> Maybe (CommaSep1' a)
listToCommaSep1' [] = Nothing
listToCommaSep1' [a] = Just (CommaSepOne1' a Nothing)
listToCommaSep1' (a:as) =
  CommaSepMany1' a (Comma [Space]) <$> listToCommaSep1' as

instance HasTrailingWhitespace s => HasTrailingWhitespace (CommaSep1' s) where
  trailingWhitespace =
    lens
      (\case
         CommaSepOne1' a b -> maybe (a ^. trailingWhitespace) (^. trailingWhitespace) b
         CommaSepMany1' _ _ a -> a ^. trailingWhitespace)
      (\cs ws ->
         case cs of
           CommaSepOne1' a b ->
             CommaSepOne1'
               (fromMaybe (a & trailingWhitespace .~ ws) $ b $> coerce a)
               (b $> Comma ws)
           CommaSepMany1' a b c ->
             CommaSepMany1' (coerce a) b (c & trailingWhitespace .~ ws))
