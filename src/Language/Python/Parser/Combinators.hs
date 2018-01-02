module Language.Python.Parser.Combinators where

import Papa hiding (Space)
import Data.Functor.Compose
import Data.Separated.After
import Data.Separated.Before
import Data.Separated.Between
import Text.Parser.Char
import Text.Parser.Combinators (try)

import Language.Python.AST.Symbols
import Language.Python.Parser.Symbols

whitespaceBefore :: CharParsing m => m a -> m (Before [WhitespaceChar] a)
whitespaceBefore m = Before <$> many whitespaceChar <*> m

anyWhitespaceBefore :: CharParsing m => m a -> m (Before [AnyWhitespaceChar] a)
anyWhitespaceBefore m =
  Before <$>
  many anyWhitespaceChar <*>
  m

whitespaceBeforeF
  :: CharParsing m
  => m (f a)
  -> m (Compose (Before [WhitespaceChar]) f a)
whitespaceBeforeF = fmap Compose . whitespaceBefore

anyWhitespaceBeforeF
  :: CharParsing m
  => m (f a)
  -> m (Compose (Before [AnyWhitespaceChar]) f a)
anyWhitespaceBeforeF = fmap Compose . anyWhitespaceBefore

before1
  :: CharParsing m
  => m ws
  -> m a
  -> m (Before (NonEmpty ws) a)
before1 ws m = Before <$> some1 (try ws) <*> m

whitespaceBefore1
  :: CharParsing m
  => m a
  -> m (Before (NonEmpty WhitespaceChar) a)
whitespaceBefore1 = before1 whitespaceChar

before1F
  :: CharParsing m
  => m ws
  -> m (f a)
  -> m (Compose (Before (NonEmpty ws)) f a)
before1F ws = fmap Compose . before1 ws

whitespaceBefore1F
  :: CharParsing m
  => m (f a)
  -> m (Compose (Before (NonEmpty WhitespaceChar)) f a)
whitespaceBefore1F = before1F whitespaceChar

whitespaceAfter :: CharParsing m => m a -> m (After [WhitespaceChar] a)
whitespaceAfter m = flip After <$> m <*> many whitespaceChar

anyWhitespaceAfter :: CharParsing m => m a -> m (After [AnyWhitespaceChar] a)
anyWhitespaceAfter m =
  flip After <$>
  m <*>
  many anyWhitespaceChar

whitespaceAfterF
  :: CharParsing m
  => m (f a)
  -> m (Compose (After [WhitespaceChar]) f a)
whitespaceAfterF = fmap Compose . whitespaceAfter

anyWhitespaceAfterF
  :: CharParsing m
  => m (f a)
  -> m (Compose (After [AnyWhitespaceChar]) f a)
anyWhitespaceAfterF = fmap Compose . anyWhitespaceAfter

after1
  :: CharParsing m
  => m ws
  -> m a
  -> m (After (NonEmpty ws) a)
after1 ws m = flip After <$> m <*> some1 (try ws)

whitespaceAfter1
  :: CharParsing m
  => m a
  -> m (After (NonEmpty WhitespaceChar) a)
whitespaceAfter1 = after1 whitespaceChar

after1F
  :: CharParsing m
  => m ws
  -> m (f a)
  -> m (Compose (After (NonEmpty ws)) f a)
after1F ws = fmap Compose . after1 ws

whitespaceAfter1F
  :: CharParsing m
  => m (f a)
  -> m (Compose (After (NonEmpty WhitespaceChar)) f a)
whitespaceAfter1F = after1F whitespaceChar

betweenWhitespace
  :: CharParsing m
  => m a
  -> m (Between' [WhitespaceChar] a)
betweenWhitespace m =
  fmap Between' $
  Between <$>
  many whitespaceChar <*>
  m <*>
  many whitespaceChar

betweenAnyWhitespace
  :: CharParsing m
  => m a
  -> m (Between' [AnyWhitespaceChar] a)
betweenAnyWhitespace m =
  fmap Between' $
  Between <$>
  many anyWhitespaceChar <*>
  m <*>
  many anyWhitespaceChar

betweenWhitespaceF
  :: CharParsing m
  => m (f a)
  -> m (Compose (Between' [WhitespaceChar]) f a)
betweenWhitespaceF = fmap Compose . betweenWhitespace

between'1
  :: CharParsing m
  => m ws
  -> m a
  -> m (Between' (NonEmpty ws) a)
between'1 ws m =
  fmap Between' $
  Between <$>
  some1 (try ws) <*>
  m <*>
  some1 (try ws)

betweenWhitespace1
  :: CharParsing m
  => m a
  -> m (Between' (NonEmpty WhitespaceChar) a)
betweenWhitespace1 m =
  fmap Between' $
  Between <$>
  some1 (try whitespaceChar) <*>
  m <*>
  some1 (try whitespaceChar)

betweenWhitespace1F
  :: CharParsing m
  => m (f a)
  -> m (Compose (Between' (NonEmpty WhitespaceChar)) f a)
betweenWhitespace1F = fmap Compose . betweenWhitespace1

optionalF :: Alternative m => m (f a) -> m (Compose Maybe f a)
optionalF m = Compose <$> optional m

some1F :: Alternative m => m (f a) -> m (Compose NonEmpty f a)
some1F m = Compose <$> some1 m

manyF :: Alternative m => m (f a) -> m (Compose [] f a)
manyF m = Compose <$> many m

after :: Applicative m => m s -> m a -> m (After s a)
after ms ma = flip After <$> ma <*> ms

afterF :: Applicative m => m s -> m (f a) -> m (Compose (After s) f a)
afterF ms ma = fmap Compose $ flip After <$> ma <*> ms

before :: Applicative m => m s -> m a -> m (Before s a)
before ms ma = Before <$> ms <*> ma

beforeF :: Applicative m => m s -> m (f a) -> m (Compose (Before s) f a)
beforeF ms ma = fmap Compose $ Before <$> ms <*> ma

betweenF
  :: Applicative m
  => m s
  -> m t
  -> m (f a)
  -> m (Compose (Between s t) f a)
betweenF ms mt ma = fmap Compose $ Between <$> ms <*> ma <*> mt

between'F
  :: Applicative m
  => m s
  -> m (f a)
  -> m (Compose (Between' s) f a)
between'F ms ma = fmap (Compose . Between') $ Between <$> ms <*> ma <*> ms

between'
  :: Applicative m
  => m s
  -> m a
  -> m (Between' s a)
between' ms ma = fmap Between' $ Between <$> ms <*> ma <*> ms
