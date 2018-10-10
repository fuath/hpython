{-# language DataKinds, TypeOperators #-}
{-# language ScopedTypeVariables, TypeApplications #-}
{-# language LambdaCase #-}
module Language.Python.Validate.Indentation
  ( module Language.Python.Validate.Indentation.Error
  , Indentation
  , runValidateIndentation
  , validateModuleIndentation
  , validateStatementIndentation
  , validateExprIndentation
    -- * Miscellany
  , NextIndent(..)
  , runValidateIndentation'
  , validateArgsIndentation
  , validateBlockIndentation
  , validateCompoundStatementIndentation
  , validateDecoratorIndentation
  , validateExceptAsIndentation
  , validateParamsIndentation
  , validateSuiteIndentation
  , equivalentIndentation
  )
where

import Control.Lens.Cons (_head)
import Control.Lens.Fold ((^?!), folded)
import Control.Lens.Getter ((^.))
import Control.Lens.Iso (from)
import Control.Lens.Prism (_Right)
import Control.Lens.Review ((#))
import Control.Lens.Setter (over, mapped)
import Control.Lens.Traversal (traverseOf)
import Control.Lens.Tuple (_2)
import Control.Monad.State (State, evalState, get, put)
import Data.Coerce (coerce)
import Data.Foldable (fold)
import Data.Functor.Compose (Compose(..))
import Data.List.NonEmpty (NonEmpty(..))
import Data.Type.Set
import Unsafe.Coerce (unsafeCoerce)
import Data.Validation (Validation(..))
import Data.Validate.Monadic (ValidateM(..), liftVM0, errorVM, errorVM1)
import qualified Data.List.NonEmpty as NonEmpty

import Language.Python.Internal.Optics
import Language.Python.Internal.Optics.Validated (unvalidated)
import Language.Python.Internal.Syntax
import Language.Python.Validate.Indentation.Error

data Indentation

-- | "The next line must be..."
data NextIndent
  = GreaterThan
  | EqualTo
  deriving (Eq, Show)

type ValidateIndentation e = ValidateM (NonEmpty e) (State (NextIndent, [Indent]))

runValidateIndentation :: ValidateIndentation e a -> Validation (NonEmpty e) a
runValidateIndentation = runValidateIndentation' EqualTo []

runValidateIndentation' :: NextIndent -> [Indent] -> ValidateIndentation e a -> Validation (NonEmpty e) a
runValidateIndentation' ni is =
  flip evalState (ni, is) .
  getCompose .
  unValidateM

withNextIndent
  :: (NextIndent -> [Indent] -> ValidateIndentation e a)
  -> ValidateIndentation e a
withNextIndent f =
  ValidateM . Compose $
    get >>= getCompose . unValidateM . uncurry f

checkIndent :: AsIndentationError e v a => Indents a -> ValidateIndentation e (Indents a)
checkIndent i =
  withNextIndent $ \ni i' ->
  let
    a = i ^. indentsAnn
    ii = fold (i ^. indentsValue)
    ii' = fold i'
    absolute1Comparison = compare (absoluteIndentLevel 1 ii) (absoluteIndentLevel 1 ii')
    absolute8Comparison = compare (absoluteIndentLevel 8 ii) (absoluteIndentLevel 8 ii')
  in
    case ni of
      GreaterThan ->
        case (absolute1Comparison, absolute8Comparison) of
          (GT, GT) -> pure i
          (GT, _) -> errorVM $ pure (_TabError # a)
          (_, GT) -> errorVM $ pure (_TabError # a)
          (EQ, EQ) -> errorVM $ pure (_ExpectedGreaterThan # (i', i))
          (_, EQ) -> errorVM $ pure (_TabError # a)
          (EQ, _) -> errorVM $ pure (_TabError # a)
          (LT, LT) -> errorVM $ pure (_ExpectedGreaterThan # (i', i))
      EqualTo ->
        case (absolute1Comparison, absolute8Comparison) of
          (EQ, EQ) -> pure i
          (EQ, _) -> errorVM $ pure (_TabError # a)
          (_, EQ) -> errorVM $ pure (_TabError # a)
          (GT, GT) -> errorVM $ pure (_ExpectedEqualTo # (i', i))
          (_, GT) -> errorVM $ pure (_TabError # a)
          (GT, _) -> errorVM $ pure (_TabError # a)
          (LT, LT) -> errorVM $ pure (_ExpectedEqualTo # (i', i))

setNextIndent :: NextIndent -> [Indent] -> ValidateIndentation e ()
setNextIndent ni is = liftVM0 $ put (ni, is)

equivalentIndentation :: [Whitespace] -> [Whitespace] -> Bool
equivalentIndentation [] [] = True
equivalentIndentation (x:_) [] =
  case x of
    Continued _ _ -> True
    _ -> False
equivalentIndentation [] (y:_) =
  case y of
    Continued _ _ -> True
    _ -> False
equivalentIndentation (x:xs) (y:ys) =
  case (x, y) of
    (Space, Space) -> equivalentIndentation xs ys
    (Tab, Tab) -> equivalentIndentation xs ys
    (Continued _ _, Continued _ _) -> True
    _ -> False

validateBlockIndentation
  :: forall e v a.
     AsIndentationError e v a
  => Block v a
  -> ValidateIndentation e (Block (Nub (Indentation ': v)) a)
validateBlockIndentation (Block x b bs) =
  (\x' (b' :| bs') ->
     case b' of
       Right b'' -> Block x' b'' bs'
       _ -> error "impossible") <$>
  traverseOf _head checkBlankIndents x <*>
  go False (Right b) bs
  where
    checkBlankIndents
      :: (a, [Whitespace], Maybe (Comment a), Newline)
      -> ValidateIndentation e (a, [Whitespace], Maybe (Comment a), Newline)
    checkBlankIndents (a, b, c, d) =
      if any (\case; Continued{} -> True; _ -> False) b
      then errorVM1 $ _EmptyContinuedLine # a
      else pure (a, b, c, d)

    is = (Right b:|bs) ^?! folded._Right.unvalidated._Indents.indentsValue

    go flag (Left e) rest =
        case rest of
          [] -> pure . Left <$> checkBlankIndents e
          r : rs -> NonEmpty.cons . Left <$> checkBlankIndents e <*> go flag r rs
    go flag (Right st) rest =
      let
        validated =
          Right <$
          (if flag then setNextIndent EqualTo is else pure ()) <*>
          validateStatementIndentation st
      in
      case rest of
        [] -> (:| []) <$> validated
        r : rs -> NonEmpty.cons <$> validated <*> go True r rs

validateSuiteIndentation
  :: AsIndentationError e v a
  => Indents a
  -> Suite v a
  -> ValidateIndentation e (Suite (Nub (Indentation ': v)) a)
validateSuiteIndentation idnt (SuiteMany ann a b c d) =
  SuiteMany ann a b c <$
  setNextIndent GreaterThan (idnt ^. indentsValue) <*>
  validateBlockIndentation d
validateSuiteIndentation _ (SuiteOne ann a b c) = pure $ SuiteOne ann a (unsafeCoerce b) c

validateExprIndentation
  :: AsIndentationError e v a
  => Expr v a
  -> ValidateIndentation e (Expr (Nub (Indentation ': v)) a)
validateExprIndentation e = pure $ unsafeCoerce e

validateParamsIndentation
  :: AsIndentationError e v a
  => CommaSep (Param v a)
  -> ValidateIndentation e (CommaSep (Param (Nub (Indentation ': v)) a))
validateParamsIndentation e = pure $ unsafeCoerce e

validateArgsIndentation
  :: AsIndentationError e v a
  => CommaSep (Arg v a)
  -> ValidateIndentation e (CommaSep (Arg (Nub (Indentation ': v)) a))
validateArgsIndentation e = pure $ unsafeCoerce e

validateExceptAsIndentation
  :: AsIndentationError e v a
  => ExceptAs v a
  -> ValidateIndentation e (ExceptAs (Nub (Indentation ': v)) a)
validateExceptAsIndentation (ExceptAs ann e f) =
  ExceptAs ann <$>
  validateExprIndentation e <*>
  pure (over (traverse._2) coerce f)

validateDecoratorIndentation
  :: AsIndentationError e v a
  => Decorator v a
  -> ValidateIndentation e (Decorator (Nub (Indentation ': v)) a)
validateDecoratorIndentation (Decorator a b c d e f) =
  (\b' -> Decorator a b' c (unsafeCoerce d) e f) <$>
  checkIndent b

validateCompoundStatementIndentation
  :: forall e v a
   . AsIndentationError e v a
  => CompoundStatement v a
  -> ValidateIndentation e (CompoundStatement (Nub (Indentation ': v)) a)
validateCompoundStatementIndentation (Fundef a decos idnt asyncWs ws1 name ws2 params ws3 mty s) =
  (\decos' idnt' params' ->
     Fundef a decos' idnt' asyncWs ws1 (coerce name) ws2 params' ws3 (unsafeCoerce mty)) <$>
  traverse validateDecoratorIndentation decos <*>
  checkIndent idnt <*>
  validateParamsIndentation params <*>
  validateSuiteIndentation idnt s
validateCompoundStatementIndentation (If a idnt ws1 expr s elifs body1) =
  (\idnt' -> If a idnt' ws1) <$>
  checkIndent idnt <*>
  validateExprIndentation expr <*>
  validateSuiteIndentation idnt s <*>
  traverse
    (\(idnt2, a, b, c) ->
       (,,,) <$
       setNextIndent EqualTo (idnt ^. indentsValue) <*>
       checkIndent idnt2 <*>
       pure a <*>
       validateExprIndentation b <*>
       validateSuiteIndentation idnt c)
    elifs <*>
  traverse
    (\(idnt2, a, b) ->
       (,,) <$
       setNextIndent EqualTo (idnt ^. indentsValue) <*>
       checkIndent idnt2 <*>
       pure a <*>
       validateSuiteIndentation idnt b)
    body1
validateCompoundStatementIndentation (While a idnt ws1 expr s) =
  (\idnt' expr' -> While a idnt' ws1 expr') <$>
  checkIndent idnt <*>
  validateExprIndentation expr <*>
  validateSuiteIndentation idnt s
validateCompoundStatementIndentation (TryExcept a idnt b c d e f) =
  (\idnt' -> TryExcept a idnt' b) <$>
  checkIndent idnt <*>
  validateSuiteIndentation idnt c <*>
  traverse
    (\(a, b, c, d) ->
       (\a' -> (,,,) a' b) <$
       setNextIndent EqualTo (idnt ^. indentsValue) <*>
       checkIndent a <*>
       traverse validateExceptAsIndentation c <*>
       validateSuiteIndentation idnt d)
    d <*
  setNextIndent EqualTo (idnt ^. indentsValue) <*>
  traverse
    (\(idnt2, a, b) ->
       (\idnt2' -> (,,) idnt2' a) <$
       setNextIndent EqualTo (idnt ^. indentsValue) <*>
       checkIndent idnt2 <*>
       validateSuiteIndentation idnt b)
    e <*
  setNextIndent EqualTo (idnt ^. indentsValue) <*>
  traverse
    (\(idnt2, a, b) ->
       (\idnt2' -> (,,) idnt2' a) <$
       setNextIndent EqualTo (idnt ^. indentsValue) <*>
       checkIndent idnt2 <*>
       validateSuiteIndentation idnt b)
    f
validateCompoundStatementIndentation (TryFinally a idnt b c idnt2 d e) =
  (\idnt' c' idnt2' -> TryFinally a idnt' b c' idnt2' d) <$>
  checkIndent idnt <*>
  validateSuiteIndentation idnt c <*
  setNextIndent EqualTo (idnt ^. indentsValue) <*>
  checkIndent idnt2 <*>
  validateSuiteIndentation idnt e
validateCompoundStatementIndentation (For a idnt asyncWs b c d e h i) =
  (\idnt' c' -> For a idnt' asyncWs b c' d) <$>
  checkIndent idnt <*>
  validateExprIndentation c <*>
  traverse validateExprIndentation e <*>
  validateSuiteIndentation idnt h <*
  setNextIndent EqualTo (idnt ^. indentsValue) <*>
  traverse
    (\(idnt2, a, b) ->
       (\idnt2' -> (,,) idnt2' a) <$
       setNextIndent EqualTo (idnt ^. indentsValue) <*>
       checkIndent idnt2 <*>
       validateSuiteIndentation idnt b)
    i
validateCompoundStatementIndentation (ClassDef a decos idnt b c d e) =
  (\decos' idnt' ->
     ClassDef @(Nub (Indentation ': v)) a decos' idnt' b (coerce c) (unsafeCoerce d)) <$>
  traverse validateDecoratorIndentation decos <*>
  checkIndent idnt <*>
  validateSuiteIndentation idnt e
validateCompoundStatementIndentation (With a idnt asyncWs b c d) =
  (\idnt' -> With @(Nub (Indentation ': v)) a idnt' asyncWs b) <$>
  checkIndent idnt <*>
  traverse validateWithItemIndentation c <*>
  validateSuiteIndentation idnt d

validateWithItemIndentation
  :: AsIndentationError e v a
  => WithItem v a
  -> ValidateIndentation e (WithItem (Nub (Indentation ': v)) a)
validateWithItemIndentation a = pure $ unsafeCoerce a

validateStatementIndentation
  :: AsIndentationError e v a
  => Statement v a
  -> ValidateIndentation e (Statement (Nub (Indentation ': v)) a)
validateStatementIndentation (CompoundStatement c) =
  CompoundStatement <$> validateCompoundStatementIndentation c
validateStatementIndentation (SmallStatements idnt a b c d) =
  (\idnt' ->
     SmallStatements idnt' (unsafeCoerce a) (over (mapped._2) unsafeCoerce b) c d) <$>
  checkIndent idnt

validateModuleIndentation
  :: AsIndentationError e v a
  => Module v a
  -> ValidateIndentation e (Module (Nub (Indentation ': v)) a)
validateModuleIndentation m =
  case m of
    ModuleEmpty -> pure ModuleEmpty
    ModuleBlankFinal a b c ->
      ModuleBlankFinal a <$>
      checkBlankWs a b <*>
      pure c
    ModuleBlank a b c d e ->
      (\b' e' -> ModuleBlank a b' c d e') <$>
      checkBlankWs a b <*>
      validateModuleIndentation e
    ModuleStatement a b ->
     ModuleStatement <$
     setNextIndent EqualTo [] <*>
     validateStatementIndentation a <*>
     validateModuleIndentation b
  where
    checkBlankWs a ws =
      if any (\case; Continued{} -> True; _ -> False) ws
      then errorVM1 $ _ExpectedEqualTo # ([], Indents [ws ^. from indentWhitespaces] a)
      else pure ws
