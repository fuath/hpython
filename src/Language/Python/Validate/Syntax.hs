{-# language DataKinds #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language FlexibleContexts #-}
{-# language PolyKinds #-}
{-# language TypeOperators #-}
{-# language TypeSynonymInstances, FlexibleInstances #-}
{-# language TemplateHaskell, TypeFamilies, MultiParamTypeClasses #-}
{-# language RankNTypes #-}
{-# language LambdaCase #-}
module Language.Python.Validate.Syntax
  ( module Language.Python.Validate.Syntax.Error
  , Syntax
  , SyntaxContext(..), inLoop, inFunction, inGenerator, inParens
  , initialSyntaxContext
  , runValidateSyntax
  , validateModuleSyntax
  , validateStatementSyntax
  , validateExprSyntax
    -- * Miscellany
  , canAssignTo
  , deleteBy'
  , deleteFirstsBy'
  , localNonlocals
  , validateArgsSyntax
  , validateBlockSyntax
  , validateCompoundStatementSyntax
  , validateComprehensionSyntax
  , validateDecoratorSyntax
  , validateDictItemSyntax
  , validateExceptAsSyntax
  , validateIdentSyntax
  , validateImportAsSyntax
  , validateImportTargetsSyntax
  , validateListItemSyntax
  , validateParamsSyntax
  , validateSetItemSyntax
  , validateSmallStatementSyntax
  , validateStringLiteralSyntax
  , validateSubscriptSyntax
  , validateSuiteSyntax
  , validateTupleItemSyntax
  , validateWhitespace
  )
where

import Control.Applicative ((<|>), liftA2)
import Control.Lens.Cons (snoc, _init)
import Control.Lens.Fold
  ((^..), (^?), (^?!), folded, allOf, toListOf, anyOf, lengthOf, has)
import Control.Lens.Getter ((^.), getting, view)
import Control.Lens.Prism (_Just)
import Control.Lens.Review ((#))
import Control.Lens.Setter ((.~), (%~))
import Control.Lens.TH (makeLenses)
import Control.Lens.Tuple (_2, _3)
import Control.Lens.Traversal (traverseOf)
import Control.Monad (when)
import Control.Monad.State (State, put, modify, get, evalState)
import Control.Monad.Reader (ReaderT, local, ask, runReaderT)
import Data.Char (isAscii, ord)
import Data.Coerce (coerce)
import Data.Foldable (toList, traverse_)
import Data.Bitraversable (bitraverse)
import Data.Functor.Compose (Compose(..))
import Data.List (intersect, union)
import Data.List.NonEmpty (NonEmpty(..), (<|))
import Data.Maybe (isJust, isNothing, fromMaybe)
import Data.Semigroup (Semigroup(..))
import Data.Type.Set (Nub, Member)
import Data.Validation (Validation(..))
import Data.Validate.Monadic (ValidateM(..), bindVM, liftVM0, liftVM1, errorVM, errorVM1)
import Unsafe.Coerce (unsafeCoerce)

import qualified Data.List.NonEmpty as NonEmpty

import Language.Python.Internal.Optics
import Language.Python.Internal.Optics.Validated (unvalidated)
import Language.Python.Internal.Syntax
import Language.Python.Validate.Indentation
import Language.Python.Validate.Syntax.Error

deleteBy' :: (a -> b -> Bool) -> a -> [b] -> [b]
deleteBy' _ _ [] = []
deleteBy' eq a (b:bs) = if a `eq` b then bs else b : deleteBy' eq a bs

deleteFirstsBy' :: (a -> b -> Bool) -> [a] -> [b] -> [a]
deleteFirstsBy' eq = foldl (flip (deleteBy' (flip eq)))

data Syntax

data FunctionInfo
  = FunctionInfo
  { _functionParams :: [String]
  , _asyncFunction :: Bool
  }
makeLenses ''FunctionInfo

data SyntaxContext
  = SyntaxContext
  { _inLoop :: Bool
  , _inFinally :: Bool
  , _inFunction :: Maybe FunctionInfo
  , _inGenerator :: Bool
  , _inClass :: Bool
  , _inParens :: Bool
  }
makeLenses ''SyntaxContext

type ValidateSyntax e = ValidateM (NonEmpty e) (ReaderT SyntaxContext (State [String]))

runValidateSyntax :: SyntaxContext -> [String] -> ValidateSyntax e a -> Validation (NonEmpty e) a
runValidateSyntax ctxt nlscope =
  flip evalState nlscope .
  flip runReaderT ctxt . getCompose .
  unValidateM

localNonlocals :: ([String] -> [String]) -> ValidateSyntax e a -> ValidateSyntax e a
localNonlocals f v =
  ValidateM . Compose $ do
    before <- get
    modify f
    res <- getCompose $ unValidateM v
    put before
    pure res

initialSyntaxContext :: SyntaxContext
initialSyntaxContext =
  SyntaxContext
  { _inLoop = False
  , _inFinally = False
  , _inFunction = Nothing
  , _inGenerator = False
  , _inClass = False
  , _inParens = False
  }

validateIdentSyntax
  :: ( AsSyntaxError e v ann
     , Member Indentation v
     )
  => Ident v ann
  -> ValidateSyntax e (Ident (Nub (Syntax ': v)) ann)
validateIdentSyntax (MkIdent a name ws)
  | not (all isAscii name) = errorVM1 (_BadCharacter # (a, name))
  | null name = errorVM1 (_EmptyIdentifier # a)
  | otherwise =
      bindVM (view inFunction) $ \fi ->
        let
          reserved =
            reservedWords <>
            if fromMaybe False (fi ^? _Just.asyncFunction)
            then ["async", "await"]
            else []
        in
          if (name `elem` reserved)
            then errorVM1 (_IdentifierReservedWord # (a, name))
            else pure $ MkIdent a name ws

validateWhitespace
  :: (AsSyntaxError e v a, Foldable f)
  => a
  -> f Whitespace
  -> ValidateSyntax e (f Whitespace)
validateWhitespace ann ws =
  ask `bindVM` \ctxt ->
  if _inParens ctxt
  then pure ws
  else if
    any
      (\case
          Newline{} -> True
          Comment{} -> False
          Continued{} -> False
          Tab -> False
          Space -> False)
      ws
  then errorVM1 (_UnexpectedNewline # ann)
  else if
    any
      (\case
          Newline{} -> False
          Comment{} -> True
          Continued{} -> False
          Tab -> False
          Space -> False)
      ws
  then errorVM1 (_UnexpectedComment # ann)
  else pure ws

validateAssignmentSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => a
  -> Expr v a
  -> ValidateSyntax e (Expr (Nub (Syntax ': v)) a)
validateAssignmentSyntax a ex =
  (if
     lengthOf (getting $ _Tuple.tupleItems._TupleUnpack) ex > 1 ||
     lengthOf (getting $ _List.listItems._ListUnpack) ex > 1
   then errorVM1 $ _ManyStarredTargets # a
   else pure ()) *>
  (if canAssignTo ex
   then validateExprSyntax ex
   else errorVM1 $ _CannotAssignTo # (a, ex))

validateCompForSyntax
  :: ( AsSyntaxError e v a
    , Member Indentation v
    )
  => CompFor v a
  -> ValidateSyntax e (CompFor (Nub (Syntax ': v)) a)
validateCompForSyntax (CompFor a b c d e) =
  (\c' -> CompFor a b c' d) <$>
  liftVM1 (local $ inGenerator .~ True) (validateAssignmentSyntax a c) <*>
  validateExprSyntax e

validateCompIfSyntax
  :: ( AsSyntaxError e v a
    , Member Indentation v
    )
  => CompIf v a
  -> ValidateSyntax e (CompIf (Nub (Syntax ': v)) a)
validateCompIfSyntax (CompIf a b c) =
  CompIf a b <$> liftVM1 (local $ inGenerator .~ True) (validateExprSyntax c)

validateComprehensionSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => (ex v a -> ValidateSyntax e (ex (Nub (Syntax ': v)) a))
  -> Comprehension ex v a
  -> ValidateSyntax e (Comprehension ex (Nub (Syntax ': v)) a)
validateComprehensionSyntax f (Comprehension a b c d) =
  Comprehension a <$>
  liftVM1 (local $ inGenerator .~ True) (f b) <*>
  validateCompForSyntax c <*>
  liftVM1
    (local $ inGenerator .~ True)
    (traverse
      (bitraverse validateCompForSyntax validateCompIfSyntax)
      d)

validateStringPyChar
  :: ( AsSyntaxError e v a
     )
  => a
  -> PyChar
  -> ValidateSyntax e PyChar
validateStringPyChar a (Char_lit '\0') =
  errorVM1 $ _NullByte # a
validateStringPyChar _ a = pure a

validateBytesPyChar
  :: ( AsSyntaxError e v a
     )
  => a
  -> PyChar
  -> ValidateSyntax e PyChar
validateBytesPyChar a (Char_lit '\0') =
  errorVM1 $ _NullByte # a
validateBytesPyChar a (Char_lit c) | ord c >= 128 =
  errorVM1 $ _NonAsciiInBytes # (a, c)
validateBytesPyChar _ a = pure a

validateStringLiteralSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => StringLiteral a
  -> ValidateSyntax e (StringLiteral a)
validateStringLiteralSyntax (StringLiteral a b c d e f) =
  StringLiteral a b c d <$>
  traverse (validateStringPyChar a) e <*>
  validateWhitespace a f
validateStringLiteralSyntax (BytesLiteral a b c d e f) =
  BytesLiteral a b c d <$>
  traverse (validateBytesPyChar a) e <*>
  validateWhitespace a f
validateStringLiteralSyntax (RawStringLiteral a b c d e f) =
  RawStringLiteral a b c d e <$>
  validateWhitespace a f
validateStringLiteralSyntax (RawBytesLiteral a b c d e f) =
  RawBytesLiteral a b c d e <$>
  validateWhitespace a f

validateDictItemSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => DictItem v a
  -> ValidateSyntax e (DictItem (Nub (Syntax ': v)) a)
validateDictItemSyntax (DictItem a b c d) =
  (\b' -> DictItem a b' c) <$>
  validateExprSyntax b <*>
  validateExprSyntax d
validateDictItemSyntax (DictUnpack a b c) =
  DictUnpack a <$>
  validateWhitespace a b <*>
  validateExprSyntax c

validateSubscriptSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Subscript v a
  -> ValidateSyntax e (Subscript (Nub (Syntax ': v)) a)
validateSubscriptSyntax (SubscriptExpr e) = SubscriptExpr <$> validateExprSyntax e
validateSubscriptSyntax (SubscriptSlice a b c d) =
  (\a' -> SubscriptSlice a' b) <$>
  traverse validateExprSyntax a <*>
  traverse validateExprSyntax c <*>
  traverseOf (traverse._2.traverse) validateExprSyntax d

validateListItemSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => ListItem v a
  -> ValidateSyntax e (ListItem (Nub (Syntax ': v)) a)
validateListItemSyntax (ListItem a b) = ListItem a <$> validateExprSyntax b
validateListItemSyntax (ListUnpack a b c d) =
  ListUnpack a <$>
  traverseOf (traverse._2) (validateWhitespace a) b <*>
  validateWhitespace a c <*>
  validateExprSyntax d

validateSetItemSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => SetItem v a
  -> ValidateSyntax e (SetItem (Nub (Syntax ': v)) a)
validateSetItemSyntax (SetItem a b) = SetItem a <$> validateExprSyntax b
validateSetItemSyntax (SetUnpack a b c d) =
  SetUnpack a <$>
  traverseOf (traverse._2) (validateWhitespace a) b <*>
  validateWhitespace a c <*>
  validateExprSyntax d

validateTupleItemSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => TupleItem v a
  -> ValidateSyntax e (TupleItem (Nub (Syntax ': v)) a)
validateTupleItemSyntax (TupleItem a b) = TupleItem a <$> validateExprSyntax b
validateTupleItemSyntax (TupleUnpack a b c d) =
  TupleUnpack a <$>
  traverseOf (traverse._2) (validateWhitespace a) b <*>
  validateWhitespace a c <*>
  validateExprSyntax d

validateExprSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Expr v a
  -> ValidateSyntax e (Expr (Nub (Syntax ': v)) a)
validateExprSyntax (Unit a b c) =
  Unit a <$>
  liftVM1 (local $ inParens .~ True) (validateWhitespace a b) <*>
  validateWhitespace a c
validateExprSyntax (Lambda a b c d e) =
  let
    paramIdents = c ^.. folded.unvalidated.paramName.identValue
  in
    Lambda a <$>
    validateWhitespace a b <*>
    validateParamsSyntax True c <*>
    validateWhitespace a d <*>
    liftVM1
      (local $
       \ctxt ->
          ctxt
          { _inLoop = False
          , _inFunction =
              fmap
                ((functionParams %~ (`union` paramIdents)) . (asyncFunction .~ False))
                (_inFunction ctxt) <|>
              Just (FunctionInfo paramIdents False)
          })
      (validateExprSyntax e)
validateExprSyntax (Yield a b c) =
  Yield a <$>
  validateWhitespace a b <*
  (ask `bindVM` \ctxt ->
      case _inFunction ctxt of
        Nothing
          | _inGenerator ctxt -> pure ()
          | otherwise -> errorVM1 (_YieldOutsideGenerator # a)
        Just info ->
          if info^.asyncFunction
          then errorVM1 $ _YieldInsideCoroutine # a
          else pure ()) <*>
  traverse validateExprSyntax c
validateExprSyntax (YieldFrom a b c d) =
  YieldFrom a <$>
  validateWhitespace a b <*>
  validateWhitespace a c <*
  (ask `bindVM` \ctxt ->
      case _inFunction ctxt of
        Nothing
          | _inGenerator ctxt -> pure ()
          | otherwise -> errorVM1 (_YieldOutsideGenerator # a)
        Just fi ->
          if fi ^. asyncFunction
          then errorVM1 (_YieldFromInsideCoroutine # a)
          else pure ()) <*>
  validateExprSyntax d
validateExprSyntax (Ternary a b c d e f) =
  (\b' d' f' -> Ternary a b' c d' e f') <$>
  validateExprSyntax b <*>
  validateExprSyntax d <*>
  validateExprSyntax f
validateExprSyntax (Subscript a b c d e) =
  (\b' d' -> Subscript a b' c d' e) <$>
  validateExprSyntax b <*>
  traverse validateSubscriptSyntax d
validateExprSyntax (Not a ws e) =
  Not a <$>
  validateWhitespace a ws <*>
  validateExprSyntax e
validateExprSyntax (Parens a ws1 e ws2) =
  Parens a ws1 <$>
  liftVM1 (local $ inParens .~ True) (validateExprSyntax e) <*>
  validateWhitespace a ws2
validateExprSyntax (Bool a b ws) = pure $ Bool a b ws
validateExprSyntax (UnOp a op expr) =
  UnOp a op <$> validateExprSyntax expr
validateExprSyntax (String a strLits) =
  if
    all
      (\case
          StringLiteral{} -> True
          RawStringLiteral{} -> True
          _ -> False)
      strLits
      ||
    all
      (\case
          BytesLiteral{} -> True
          RawBytesLiteral{} -> True
          _ -> False)
      strLits
  then
    String a <$> traverse validateStringLiteralSyntax strLits
  else
    errorVM1 (_Can'tJoinStringAndBytes # a)
validateExprSyntax (Int a n ws) = pure $ Int a n ws
validateExprSyntax (Float a n ws) = pure $ Float a n ws
validateExprSyntax (Imag a n ws) = pure $ Imag a n ws
validateExprSyntax (Ident name) = Ident <$> validateIdentSyntax name
validateExprSyntax (List a ws1 exprs ws2) =
  List a ws1 <$>
  liftVM1
    (local $ inParens .~ True)
    (traverseOf (traverse.traverse) validateListItemSyntax exprs) <*>
  validateWhitespace a ws2
validateExprSyntax (ListComp a ws1 comp ws2) =
  liftVM1
    (local $ inParens .~ True)
    (ListComp a ws1 <$>
     validateComprehensionSyntax validateExprSyntax comp) <*>
  validateWhitespace a ws2
validateExprSyntax (Generator a comp) =
  Generator a <$> validateComprehensionSyntax validateExprSyntax comp
validateExprSyntax (Await a ws expr) =
  bindVM ask $ \ctxt ->
  Await a <$>
  validateWhitespace a ws <*
  (if not $ fromMaybe False (ctxt ^? inFunction._Just.asyncFunction)
   then errorVM1 $ _AwaitOutsideCoroutine # a
   else pure () *>
   if ctxt^.inGenerator
   then errorVM1 $ _AwaitInsideComprehension # a
   else pure ()) <*>
  validateExprSyntax expr
validateExprSyntax (Deref a expr ws1 name) =
  Deref a <$>
  validateExprSyntax expr <*>
  validateWhitespace a ws1 <*>
  validateIdentSyntax name
validateExprSyntax (Call a expr ws args ws2) =
  Call a <$>
  validateExprSyntax expr <*>
  liftVM1 (local $ inParens .~ True) (validateWhitespace a ws) <*>
  liftVM1 (local $ inParens .~ True) (traverse validateArgsSyntax args) <*>
  validateWhitespace a ws2
validateExprSyntax (None a ws) = None a <$> validateWhitespace a ws
validateExprSyntax (Ellipsis a ws) = Ellipsis a <$> validateWhitespace a ws
validateExprSyntax (BinOp a e1 op e2) =
  BinOp a <$>
  validateExprSyntax e1 <*>
  pure op <*>
  validateExprSyntax e2
validateExprSyntax (Tuple a b ws d) =
  Tuple a <$>
  validateTupleItemSyntax b <*>
  validateWhitespace a ws <*>
  traverseOf (traverse.traverse) validateTupleItemSyntax d
validateExprSyntax (DictComp a ws1 comp ws2) =
  liftVM1
    (local $ inParens .~ True)
    (DictComp a ws1 <$>
     validateComprehensionSyntax dictItem comp) <*>
  validateWhitespace a ws2
  where
    dictItem (DictUnpack a _ _) = errorVM1 (_InvalidDictUnpacking # a)
    dictItem a = validateDictItemSyntax a
validateExprSyntax (Dict a b c d) =
  Dict a b <$>
  liftVM1
    (local $ inParens .~ True)
    (traverseOf (traverse.traverse) validateDictItemSyntax c) <*>
  validateWhitespace a d
validateExprSyntax (SetComp a ws1 comp ws2) =
  liftVM1
    (local $ inParens .~ True)
    (SetComp a ws1 <$>
     validateComprehensionSyntax setItem comp) <*>
  validateWhitespace a ws2
  where
    setItem (SetUnpack a _ _ _) = errorVM1 (_InvalidSetUnpacking # a)
    setItem a = validateSetItemSyntax a
validateExprSyntax (Set a b c d) =
  Set a b <$>
  liftVM1
    (local $ inParens .~ True)
    (traverse validateSetItemSyntax c) <*>
  validateWhitespace a d

validateBlockSyntax
  :: (Member Indentation v, AsSyntaxError e v a)
  => Block v a
  -> ValidateSyntax e (Block (Nub (Syntax ': v)) a)
validateBlockSyntax (BlockOne a b c) =
  (\a' -> BlockOne a' b) <$>
  validateStatementSyntax a <*>
  traverseOf (traverse._2.traverse) validateBlock'Syntax c
  where
    validateBlock'Syntax
      :: (Member Indentation v, AsSyntaxError e v a)
      => Block' v a
      -> ValidateSyntax e (Block' (Nub (Syntax ': v)) a)
    validateBlock'Syntax (Block'One a b c) =
      (\a' -> Block'One a' b) <$>
      validateStatementSyntax a <*>
      traverseOf (traverse._2.traverse) validateBlock'Syntax c
    validateBlock'Syntax (Block'Blank a b c d) =
      Block'Blank a b c <$> traverseOf (traverse._2.traverse) validateBlock'Syntax d
validateBlockSyntax (BlockBlank a b c d e) =
  BlockBlank a b c d <$> validateBlockSyntax e

validateSuiteSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Suite v a
  -> ValidateSyntax e (Suite (Nub (Syntax ': v)) a)
validateSuiteSyntax (SuiteMany a b c d e) =
  (\b' -> SuiteMany a b' c d) <$>
  validateWhitespace a b <*>
  validateBlockSyntax e
validateSuiteSyntax (SuiteOne a b c d) =
  (\b' c' -> SuiteOne a b' c' d) <$>
  validateWhitespace a b <*>
  validateSmallStatementSyntax c

validateDecoratorSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Decorator v a
  -> ValidateSyntax e (Decorator (Nub (Syntax ': v)) a)
validateDecoratorSyntax (Decorator a b c d e f) =
  (\c' d' -> Decorator a b c' d' e f) <$>
  validateWhitespace a c <*>
  isDecoratorValue d
  where
    someDerefs Ident{} = True
    someDerefs (Deref _ a _ _) = someDerefs a
    someDerefs _ = False

    isDecoratorValue e@(Call _ a _ _ _) | someDerefs a = pure $ unsafeCoerce e
    isDecoratorValue e | someDerefs e = pure $ unsafeCoerce e
    isDecoratorValue _ = errorVM1 (_MalformedDecorator # a)

validateCompoundStatementSyntax
  :: forall e v a
   . ( AsSyntaxError e v a
     , Member Indentation v
     )
  => CompoundStatement v a
  -> ValidateSyntax e (CompoundStatement (Nub (Syntax ': v)) a)
validateCompoundStatementSyntax (Fundef a decos idnts asyncWs ws1 name ws2 params ws3 mty body) =
  let
    paramIdents = params ^.. folded.unvalidated.paramName.identValue
  in
    (\decos' -> Fundef a decos' idnts) <$>
    traverse validateDecoratorSyntax decos <*>
    traverse (validateWhitespace a) asyncWs <*>
    validateWhitespace a ws1 <*>
    validateIdentSyntax name <*>
    pure ws2 <*>
    liftVM1 (local $ inParens .~ True) (validateParamsSyntax False params) <*>
    pure ws3 <*>
    traverse (bitraverse (validateWhitespace a) validateExprSyntax) mty <*>
    localNonlocals id
      (liftVM1
         (local $
          \ctxt ->
            ctxt
            { _inLoop = False
            , _inFunction =
                fmap
                  ((functionParams %~ (`union` paramIdents)) .
                   (asyncFunction %~ (|| isJust asyncWs)))
                  (_inFunction ctxt) <|>
                Just (FunctionInfo paramIdents $ isJust asyncWs)
            })
         (validateSuiteSyntax body))
validateCompoundStatementSyntax (If a idnts ws1 expr body elifs body') =
  If a idnts <$>
  validateWhitespace a ws1 <*>
  validateExprSyntax expr <*>
  validateSuiteSyntax body <*>
  traverse
    (\(a, b, c, d) ->
       (\c' -> (,,,) a b c') <$>
       validateExprSyntax c <*>
       validateSuiteSyntax d)
    elifs <*>
  traverseOf (traverse._3) validateSuiteSyntax body'
validateCompoundStatementSyntax (While a idnts ws1 expr body) =
  While a idnts <$>
  validateWhitespace a ws1 <*>
  validateExprSyntax expr <*>
  liftVM1 (local $ inLoop .~ True) (validateSuiteSyntax body)
validateCompoundStatementSyntax (TryExcept a idnts b e f k l) =
  TryExcept a idnts <$>
  validateWhitespace a b <*>
  validateSuiteSyntax e <*>
  traverse
    (\(idnts, f, g, j) ->
       (,,,) idnts <$>
       validateWhitespace a f <*>
       traverse validateExceptAsSyntax g <*>
       validateSuiteSyntax j)
    f <*
  (if anyOf (_init.folded._3) isNothing $ NonEmpty.toList f
   then errorVM1 $ _DefaultExceptMustBeLast # a
   else pure ()) <*>
  traverse
    (\(idnts, x, w) ->
       (,,) idnts <$>
       validateWhitespace a x <*>
       validateSuiteSyntax w)
    k <*>
  traverse
    (\(idnts, x, w) ->
       (,,) idnts <$>
       validateWhitespace a x <*>
       liftVM1 (local $ inFinally .~ True) (validateSuiteSyntax w))
    l
validateCompoundStatementSyntax (TryFinally a idnts b e idnts2 f i) =
  TryFinally a idnts <$>
  validateWhitespace a b <*>
  validateSuiteSyntax e <*> pure idnts2 <*>
  validateWhitespace a f <*>
  liftVM1 (local $ inFinally .~ True) (validateSuiteSyntax i)
validateCompoundStatementSyntax (ClassDef a decos idnts b c d g) =
  liftVM1 (local $ inLoop .~ False) $
  (\decos' -> ClassDef a decos' idnts) <$>
  traverse validateDecoratorSyntax decos <*>
  validateWhitespace a b <*>
  validateIdentSyntax c <*>
  traverse
    (\(x, y, z) ->
       (,,) <$>
       validateWhitespace a x <*>
       traverse
         (liftVM1 (local $ inParens .~ True) . validateArgsSyntax)
         y <*>
       validateWhitespace a z)
    d <*>
  liftVM1 (local $ inClass .~ True) (validateSuiteSyntax g)
validateCompoundStatementSyntax (For a idnts asyncWs b c d e h i) =
  bindVM ask $ \ctxt ->
  For a idnts <$
  (if isJust asyncWs && not (fromMaybe False $ ctxt ^? inFunction._Just.asyncFunction)
   then errorVM1 (_AsyncForOutsideCoroutine # a)
   else pure ()) <*>
  traverse (validateWhitespace a) asyncWs <*>
  validateWhitespace a b <*>
  validateAssignmentSyntax a c <*>
  validateWhitespace a d <*>
  traverse validateExprSyntax e <*>
  liftVM1 (local $ inLoop .~ True) (validateSuiteSyntax h) <*>
  traverse
    (\(idnts, x, w) ->
       (,,) idnts <$>
       validateWhitespace a x <*>
       validateSuiteSyntax w)
    i
validateCompoundStatementSyntax (With a b asyncWs c d e) =
  bindVM ask $ \ctxt ->
  With a b <$
  (if isJust asyncWs && not (fromMaybe False $ ctxt ^? inFunction._Just.asyncFunction)
   then errorVM1 (_AsyncWithOutsideCoroutine # a)
   else pure ()) <*>
  traverse (validateWhitespace a) asyncWs <*>
  validateWhitespace a c <*>
  traverse
    (\(WithItem a b c) ->
        WithItem a <$>
        validateExprSyntax b <*>
        traverse
          (\(ws, b) -> (,) <$> validateWhitespace a ws <*> validateAssignmentSyntax a b)
          c)
    d <*>
  validateSuiteSyntax e

validateExceptAsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => ExceptAs v a
  -> ValidateSyntax e (ExceptAs (Nub (Syntax ': v)) a)
validateExceptAsSyntax (ExceptAs ann e f) =
  ExceptAs ann <$>
  validateExprSyntax e <*>
  traverse (\(a, b) -> (,) <$> validateWhitespace ann a <*> validateIdentSyntax b) f

validateImportAsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => (t a -> ValidateSyntax e (t' a))
  -> ImportAs t v a
  -> ValidateSyntax e (ImportAs t' (Nub (Syntax ': v)) a)
validateImportAsSyntax v (ImportAs x a b) =
  ImportAs x <$>
  v a <*>
  traverse
    (\(c, d) ->
       (,) <$>
       (c <$ validateWhitespace x (NonEmpty.toList c)) <*>
       validateIdentSyntax d)
    b

validateImportTargetsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => ImportTargets v a
  -> ValidateSyntax e (ImportTargets (Nub (Syntax ': v)) a)
validateImportTargetsSyntax (ImportAll a ws) =
  bindVM ask $ \ctxt ->
  if ctxt ^. inClass || has (inFunction._Just) ctxt
    then errorVM1 $ _WildcardImportInDefinition # a
    else ImportAll a <$> validateWhitespace a ws
validateImportTargetsSyntax (ImportSome a cs) =
  ImportSome a <$> traverse (validateImportAsSyntax validateIdentSyntax) cs
validateImportTargetsSyntax (ImportSomeParens a ws1 cs ws2) =
  liftVM1
    (local $ inParens .~ True)
    (ImportSomeParens a <$>
     validateWhitespace a ws1 <*>
     traverse (validateImportAsSyntax validateIdentSyntax) cs) <*>
  validateWhitespace a ws2

validateSmallStatementSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => SmallStatement v a
  -> ValidateSyntax e (SmallStatement (Nub (Syntax ': v)) a)
validateSmallStatementSyntax (Assert a b c d) =
  Assert a <$>
  validateWhitespace a b <*>
  validateExprSyntax c <*>
  traverseOf (traverse._2) validateExprSyntax d
validateSmallStatementSyntax (Raise a ws f) =
  Raise a <$>
  validateWhitespace a ws <*>
  traverse
    (\(b, c) ->
       (,) <$>
       validateExprSyntax b <*>
       traverse
         (\(d, e) ->
            (,) <$>
            validateWhitespace a d <*>
            validateExprSyntax e)
         c)
    f
validateSmallStatementSyntax (Return a ws expr) =
  ask `bindVM` \sctxt ->
    case _inFunction sctxt of
      Just{} ->
        Return a <$>
        validateWhitespace a ws <*>
        traverse validateExprSyntax expr
      _ -> errorVM1 (_ReturnOutsideFunction # a)
validateSmallStatementSyntax (Expr a expr) =
  Expr a <$>
  validateExprSyntax expr
validateSmallStatementSyntax (Assign a lvalue rs) =
  ask `bindVM` \sctxt ->
    let
      assigns =
        if isJust (_inFunction sctxt)
        then
          (lvalue : (snd <$> NonEmpty.init rs)) ^..
          folded.unvalidated.assignTargets.identValue
        else []
    in
      Assign a <$>
      validateAssignmentSyntax a lvalue <*>
      ((\a b -> case a of; [] -> pure b; a : as -> a :| (snoc as b)) <$>
       traverse
         (\(ws, b) ->
            (,) <$>
            validateWhitespace a ws <*>
            validateAssignmentSyntax a b)
         (NonEmpty.init rs) <*>
       (\(ws, b) -> (,) <$> validateWhitespace a ws <*> validateExprSyntax b)
         (NonEmpty.last rs)) <*
      liftVM0 (modify (assigns ++))
validateSmallStatementSyntax (AugAssign a lvalue aa rvalue) =
  AugAssign a <$>
  (if canAssignTo lvalue
    then case lvalue of
      Ident{} -> validateExprSyntax lvalue
      Deref{} -> validateExprSyntax lvalue
      Subscript{} -> validateExprSyntax lvalue
      _ -> errorVM1 (_CannotAugAssignTo # (a, lvalue))
    else errorVM1 (_CannotAssignTo # (a, lvalue))) <*>
  pure aa <*>
  validateExprSyntax rvalue
validateSmallStatementSyntax (Pass a ws) =
  Pass a <$> validateWhitespace a ws
validateSmallStatementSyntax (Break a ws) =
  Break a <$
  (ask `bindVM` \sctxt ->
     if _inLoop sctxt
     then pure ()
     else errorVM1 (_BreakOutsideLoop # a)) <*>
  validateWhitespace a ws
validateSmallStatementSyntax (Continue a ws) =
  Continue a <$
  (ask `bindVM` \sctxt ->
     (if _inLoop sctxt
      then pure ()
      else errorVM1 (_ContinueOutsideLoop # a)) *>
     (if _inFinally sctxt
      then errorVM1 (_ContinueInsideFinally # a)
      else pure ())) <*>
  validateWhitespace a ws
validateSmallStatementSyntax (Global a ws ids) =
  Global a ws <$> traverse validateIdentSyntax ids
validateSmallStatementSyntax (Nonlocal a ws ids) =
  ask `bindVM` \sctxt ->
  get `bindVM` \nls ->
  (case deleteFirstsBy' (\a -> (==) (a ^. unvalidated.identValue)) (ids ^.. folded) nls of
     [] -> pure ()
     ids -> traverse_ (\e -> errorVM1 (_NoBindingNonlocal # e)) ids) *>
  case sctxt ^? inFunction._Just.functionParams of
    Nothing -> errorVM1 (_NonlocalOutsideFunction # a)
    Just params ->
      case intersect params (ids ^.. folded.unvalidated.identValue) of
        [] -> Nonlocal a ws <$> traverse validateIdentSyntax ids
        bad -> errorVM1 (_ParametersNonlocal # (a, bad))
validateSmallStatementSyntax (Del a ws ids) =
  Del a ws <$>
  traverse
    (\x ->
       validateExprSyntax x <*
       if canDelete x
       then pure ()
       else errorVM1 $ _CannotDelete # (a, x))
    ids
validateSmallStatementSyntax (Import a ws mns) =
  Import a ws <$> traverse (pure . coerce) mns
validateSmallStatementSyntax (From a ws1 mn ws2 ts) =
  From a ws1 (coerce mn) <$>
  validateWhitespace a ws2 <*>
  validateImportTargetsSyntax ts

canDelete :: Expr v a -> Bool
canDelete None{} = False
canDelete Ellipsis{} = False
canDelete UnOp{} = False
canDelete Int{} = False
canDelete Call{} = False
canDelete BinOp{} = False
canDelete Bool{} = False
canDelete Unit{} = False
canDelete Yield{} = False
canDelete YieldFrom{} = False
canDelete Ternary{} = False
canDelete ListComp{} = False
canDelete DictComp{} = False
canDelete Dict{} = False
canDelete SetComp{} = False
canDelete Set{} = False
canDelete Lambda{} = False
canDelete Float{} = False
canDelete Imag{} = False
canDelete Not{} = False
canDelete Generator{} = False
canDelete Await{} = False
canDelete String{} = False
canDelete (Parens _ _ a _) = canDelete a
canDelete (List _ _ a _) =
  all (allOf (folded.getting _Exprs) canDelete) a &&
  not (any (\case; ListUnpack{} -> True; _ -> False) $ a ^.. folded.folded)
canDelete (Tuple _ a _ b) =
  all
    canDelete
    ((a ^?! getting _Exprs) : toListOf (folded.folded.getting _Exprs) b) &&
  not (any (\case; TupleUnpack{} -> True; _ -> False) $ a : toListOf (folded.folded) b)
canDelete Deref{} = True
canDelete Subscript{} = True
canDelete Ident{} = True

validateStatementSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Statement v a
  -> ValidateSyntax e (Statement (Nub (Syntax ': v)) a)
validateStatementSyntax (CompoundStatement c) =
  liftVM1 (local $ inFinally .~ False) $
  CompoundStatement <$> validateCompoundStatementSyntax c
validateStatementSyntax (SmallStatements idnts s ss sc cmt) =
  (\s' ss' -> SmallStatements idnts s' ss' sc cmt) <$>
  validateSmallStatementSyntax s <*>
  traverseOf (traverse._2) validateSmallStatementSyntax ss

canAssignTo :: Expr v a -> Bool
canAssignTo None{} = False
canAssignTo Ellipsis{} = False
canAssignTo UnOp{} = False
canAssignTo Int{} = False
canAssignTo Call{} = False
canAssignTo BinOp{} = False
canAssignTo Bool{} = False
canAssignTo Unit{} = False
canAssignTo Yield{} = False
canAssignTo YieldFrom{} = False
canAssignTo Ternary{} = False
canAssignTo ListComp{} = False
canAssignTo DictComp{} = False
canAssignTo Dict{} = False
canAssignTo SetComp{} = False
canAssignTo Set{} = False
canAssignTo Lambda{} = False
canAssignTo Float{} = False
canAssignTo Imag{} = False
canAssignTo Not{} = False
canAssignTo Generator{} = False
canAssignTo Await{} = False
canAssignTo String{} = False
canAssignTo (Parens _ _ a _) = canAssignTo a
canAssignTo (List _ _ a _) =
  all (allOf (folded.getting _Exprs) canAssignTo) a
canAssignTo (Tuple _ a _ b) =
  all canAssignTo ((a ^?! getting _Exprs) : toListOf (folded.folded.getting _Exprs) b)
canAssignTo Deref{} = True
canAssignTo Subscript{} = True
canAssignTo Ident{} = True

validateArgsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => CommaSep1' (Arg v a)
  -> ValidateSyntax e (CommaSep1' (Arg (Nub (Syntax ': v)) a))
validateArgsSyntax e = unsafeCoerce e <$ go [] False False (toList e)
  where
    go
      :: (AsSyntaxError e v a, Member Indentation v)
      => [String]
      -- ^ Have we seen a keyword argument?
      -> Bool
      -- ^ Have we seen a **argument?
      -> Bool
      -> [Arg v a]
      -> ValidateSyntax e [Arg (Nub (Syntax ': v)) a]
    go _ _ _ [] = pure []
    go names False False (PositionalArg a expr : args) =
      liftA2 (:)
        (PositionalArg a <$> validateExprSyntax expr)
        (go names False False args)
    go names seenKeyword seenUnpack (PositionalArg a expr : args) =
      when seenKeyword (errorVM1 (_PositionalAfterKeywordArg # (a, expr))) *>
      when seenUnpack (errorVM1 (_PositionalAfterKeywordUnpacking # (a, expr))) *>
      go names seenKeyword seenUnpack args
    go names seenKeyword False (StarArg a ws expr : args) =
      liftA2 (:)
        (StarArg a <$> validateWhitespace a ws <*> validateExprSyntax expr)
        (go names seenKeyword False args)
    go names seenKeyword seenUnpack (StarArg a _ expr : args) =
      when seenKeyword (errorVM1 (_PositionalAfterKeywordArg # (a, expr))) *>
      when seenUnpack (errorVM1 (_PositionalAfterKeywordUnpacking # (a, expr))) *>
      go names seenKeyword seenUnpack args
    go names _ seenUnpack (KeywordArg a name ws2 expr : args)
      | _identValue name `elem` names =
          errorVM1 (_DuplicateArgument # (a, _identValue name)) <*>
          validateIdentSyntax name <*>
          go names True seenUnpack args
      | otherwise =
          liftA2 (:)
            (KeywordArg a <$>
             validateIdentSyntax name <*>
             pure ws2 <*>
             validateExprSyntax expr)
            (go (_identValue name:names) True seenUnpack args)
    go names seenKeyword _ (DoubleStarArg a ws expr : args) =
      liftA2 (:)
        (DoubleStarArg a <$>
         validateWhitespace a ws <*>
         validateExprSyntax expr)
        (go names seenKeyword True args)

newtype HaveSeenKeywordArg = HaveSeenKeywordArg Bool
newtype HaveSeenEmptyStarArg a = HaveSeenEmptyStarArg (Maybe a)

validateParamsSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Bool -- ^ These are the parameters to a lambda
  -> CommaSep (Param v a)
  -> ValidateSyntax e (CommaSep (Param (Nub (Syntax ': v)) a))
validateParamsSyntax isLambda e =
  unsafeCoerce e <$
  go [] (HaveSeenEmptyStarArg Nothing) (HaveSeenKeywordArg False) (toList e)
  where
    checkTy
      :: ( AsSyntaxError e v a
         , Member Indentation v
         )
      => a
      -> Maybe ([Whitespace], Expr v a)
      -> ValidateSyntax e (Maybe ([Whitespace], Expr (Nub (Syntax ': v)) a))
    checkTy a mty =
      if isLambda
      then traverse (\_ -> errorVM1 (_TypedParamInLambda # a)) mty
      else traverseOf (traverse._2) validateExprSyntax mty

    go
      :: ( AsSyntaxError e v a
         , Member Indentation v
         )
      => [String] -- identifiers that we've seen
      -> HaveSeenEmptyStarArg a -- have we seen an empty star argument?
      -> HaveSeenKeywordArg -- have we seen a keyword parameter?
      -> [Param v a]
      -> ValidateSyntax e [Param (Nub (Syntax ': v)) a]
    go _ (HaveSeenEmptyStarArg b) _ [] =
      case b of
        Nothing -> pure []
        Just b' -> errorVM1 $ _NoKeywordsAfterEmptyStarArg # b'
    go names bsa bkw@(HaveSeenKeywordArg False) (PositionalParam a name mty : params)
      | _identValue name `elem` names =
          errorVM1 (_DuplicateArgument # (a, _identValue name)) <*>
          validateIdentSyntax name <*>
          checkTy a mty <*>
          go (_identValue name:names) bsa bkw params
      | otherwise =
          liftA2
            (:)
            (PositionalParam a <$>
             validateIdentSyntax name <*>
             checkTy a mty)
            (go (_identValue name:names) bsa bkw params)
    go names bsa bkw (StarParam a ws mname mty : params)
      | Just name <- mname, _identValue name `elem` names =
          errorVM1 (_DuplicateArgument # (a, _identValue name)) <*>
          validateIdentSyntax name <*>
          checkTy a mty <*>
          go
            (_identValue name:names)
            (if isNothing mname then HaveSeenEmptyStarArg (Just a) else bsa)
            bkw
            params
      | otherwise =
          liftA2
            (:)
            (StarParam a ws <$>
             traverse validateIdentSyntax mname <*
             (case (mname, mty) of
                (Nothing, Just{}) -> errorVM1 (_TypedUnnamedStarParam # a)
                _ -> pure ()) <*>
             checkTy a mty)
            (go
               (maybe names (\n -> _identValue n : names) mname)
               (if isNothing mname then HaveSeenEmptyStarArg (Just a) else bsa)
               bkw
               params)
    go names bsa bkw@(HaveSeenKeywordArg True) (PositionalParam a name mty : params) =
      let
        name' = _identValue name
        errs =
          foldr (<|)
            (_PositionalAfterKeywordParam # (a, name') :| [])
            [_DuplicateArgument # (a, name') | name' `elem` names]
      in
        errorVM errs <*>
        checkTy a mty <*>
        go (name':names) bsa bkw params
    go names _ _ (KeywordParam a name mty ws2 expr : params)
      | _identValue name `elem` names =
          errorVM1 (_DuplicateArgument # (a, _identValue name)) <*>
          checkTy a mty <*>
          go names (HaveSeenEmptyStarArg Nothing) (HaveSeenKeywordArg True) params
      | otherwise =
          liftA2 (:)
            (KeywordParam a <$>
             validateIdentSyntax name <*>
             checkTy a mty <*>
             pure ws2 <*>
             validateExprSyntax expr)
            (go
               (_identValue name:names)
               (HaveSeenEmptyStarArg Nothing)
               (HaveSeenKeywordArg True)
               params)
    go names bsa bkw [DoubleStarParam a ws name mty]
      | _identValue name `elem` names =
          errorVM1 (_DuplicateArgument # (a, _identValue name)) <*>
          checkTy a mty <*
          go names bsa bkw []
      | otherwise =
          fmap pure $
          DoubleStarParam a ws <$>
          validateIdentSyntax name <*>
          checkTy a mty <*
          go names bsa bkw []
    go names bsa bkw (DoubleStarParam a _ name mty : _) =
      (if _identValue name `elem` names
       then errorVM1 (_DuplicateArgument # (a, _identValue name))
       else pure ()) *>
      errorVM1 (_UnexpectedDoubleStarParam # (a, _identValue name)) <*>
      checkTy a mty <*
      go names bsa bkw []

validateModuleSyntax
  :: ( AsSyntaxError e v a
     , Member Indentation v
     )
  => Module v a
  -> ValidateSyntax e (Module (Nub (Syntax ': v)) a)
validateModuleSyntax m =
  case m of
    ModuleEmpty -> pure ModuleEmpty
    ModuleBlankFinal a b c ->
      ModuleBlankFinal a <$> validateWhitespace a b <*> pure c
    ModuleBlank a b c d e ->
      (\b' -> ModuleBlank a b' c d) <$>
      validateWhitespace a b <*>
      validateModuleSyntax e
    ModuleStatement a b ->
     ModuleStatement <$>
     validateStatementSyntax a <*>
     validateModuleSyntax b
