{-# language DataKinds #-}
{-# language PolyKinds #-}
{-# language LambdaCase #-}
module Language.Python.Internal.Optics where

import Control.Lens.Fold (Fold)
import Control.Lens.Getter ((^.), view)
import Control.Lens.Iso (Iso', iso, from)
import Control.Lens.Setter ((.~))
import Control.Lens.Traversal (Traversal, Traversal', traverseOf)
import Control.Lens.Tuple (_3, _4)
import Control.Lens.Prism (Prism, _Right, prism)
import Data.Coerce (coerce)
import Data.Function ((&))

import Language.Python.Internal.Optics.Validated (unvalidated)
import Language.Python.Internal.Syntax
import Language.Python.Syntax.Types

_TupleUnpack :: Prism (TupleItem v a) (TupleItem '[] a) (TupleUnpack v a) (TupleUnpack '[] a)
_TupleUnpack =
  prism
    (\(MkTupleUnpack a b c d) -> TupleUnpack a b c d)
    (\case
       TupleUnpack a b c d -> Right $ MkTupleUnpack a b c d
       a -> Left $ a ^. unvalidated)

_Tuple :: Prism (Expr v a) (Expr '[] a) (Tuple v a) (Tuple '[] a)
_Tuple =
  prism
    (\(MkTuple a b c d) -> Tuple a b c d)
    (\case
        Tuple a b c d -> Right (MkTuple a b c d)
        a -> Left $ a ^. unvalidated)

tupleItems :: Traversal (Tuple v a) (Tuple '[] a) (TupleItem v a) (TupleItem '[] a)
tupleItems f (MkTuple a b c d) =
  (\b' d' -> MkTuple a b' c d') <$>
  f b <*>
  (traverse.traverse) f d

_ListUnpack :: Prism (ListItem v a) (ListItem '[] a) (ListUnpack v a) (ListUnpack '[] a)
_ListUnpack =
  prism
    (\(MkListUnpack a b c d) -> ListUnpack a b c d)
    (\case
       ListUnpack a b c d -> Right $ MkListUnpack a b c d
       a -> Left $ a ^. unvalidated)

_List :: Prism (Expr v a) (Expr '[] a) (List v a) (List '[] a)
_List =
  prism
    (\(MkList a b c d) -> List a b c d)
    (\case
        List a b c d -> Right (MkList a b c d)
        a -> Left $ a ^. unvalidated)

listItems :: Traversal (List v a) (List '[] a) (ListItem v a) (ListItem '[] a)
listItems f (MkList a b c d) =
  (\c' -> MkList a b c' d) <$>
  (traverse.traverse) f c

_None :: Prism (Expr v a) (Expr '[] a) (None v a) (None '[] a)
_None =
  prism
    (\(MkNone a b) -> None a b)
    (\case
        None a b -> Right (MkNone a b)
        a -> Left $ a ^. unvalidated)

_KeywordParam
  :: Prism
       (Param v a)
       (Param '[] a)
       (KeywordParam v a)
       (KeywordParam '[] a)
_KeywordParam =
  prism
    (\(MkKeywordParam a b c d e) -> KeywordParam a b c d e)
    (\case
        KeywordParam a b c d e -> Right (MkKeywordParam a b c d e)
        a -> Left $ a ^. unvalidated)

_PositionalParam
  :: Prism
       (Param v a)
       (Param '[] a)
       (PositionalParam v a)
       (PositionalParam '[] a)
_PositionalParam =
  prism
    (\(MkPositionalParam a b c) -> PositionalParam a b c)
    (\case
        PositionalParam a b c -> Right (MkPositionalParam a b c)
        a -> Left $ a ^. unvalidated)

_StarParam
  :: Prism
       (Param v a)
       (Param '[] a)
       (StarParam v a)
       (StarParam '[] a)
_StarParam =
  prism
    (\(MkStarParam a b c d) -> StarParam a b c d)
    (\case
        StarParam a b c d -> Right (MkStarParam a b c d)
        a -> Left $ a ^. unvalidated)

_Fundef
  :: Prism
       (Statement v a)
       (Statement '[] a)
       (Fundef v a)
       (Fundef '[] a)
_Fundef =
  prism
    (\(MkFundef idnt a b c d e f g h i j) ->
       CompoundStatement (Fundef idnt a b c d e f g h i j))
    (\case
        CompoundStatement (Fundef idnt a b c d e f g h i j) ->
          Right $ MkFundef idnt a b c d e f g h i j
        a -> Left $ a ^. unvalidated)

_While
  :: Prism
       (Statement v a)
       (Statement '[] a)
       (While v a)
       (While '[] a)
_While =
  prism
    (\(MkWhile a b c d e) ->
       CompoundStatement (While a b c d e))
    (\case
        CompoundStatement (While a b c d e) ->
          Right $ MkWhile a b c d e
        a -> Left $ a ^. unvalidated)

_Else :: Iso' (Else v a) (Indents a, [Whitespace], Suite v a)
_Else = iso (\(MkElse a b c) -> (a, b, c)) (\(a, b, c) -> MkElse a b c)

_Elif :: Iso' (Elif v a) (Indents a, [Whitespace], Expr v a, Suite v a)
_Elif = iso (\(MkElif a b c d) -> (a, b, c, d)) (\(a, b, c, d) -> MkElif a b c d)

_Finally :: Iso' (Finally v a) (Indents a, [Whitespace], Suite v a)
_Finally = iso (\(MkFinally a b c) -> (a, b, c)) (\(a, b, c) -> MkFinally a b c)

_Except :: Iso' (Except v a) (Indents a, [Whitespace], Maybe (ExceptAs v a), Suite v a)
_Except = iso (\(MkExcept a b c d) -> (a, b, c, d)) (\(a, b, c, d) -> MkExcept a b c d)

_If :: Prism (Statement v a) (Statement '[] a) (If v a) (If '[] a)
_If =
  prism
    (\(MkIf a b c d e f g) ->
       CompoundStatement (If a b c d e (view _Elif <$> f) (view _Else <$> g)))
    (\case
        CompoundStatement (If a b c d e f g) ->
          Right $ MkIf a b c d e (view (from _Elif) <$> f) (view (from _Else) <$> g)
        a -> Left $ a ^. unvalidated)

class AsTry s where
  _Try :: Prism (Statement v a) (Statement '[] a) (s v a) (s '[] a)

instance AsTry TryExcept where
  _Try = _TryExcept

instance AsTry TryFinally where
  _Try = _TryFinally

_TryExcept :: Prism (Statement v a) (Statement '[] a) (TryExcept v a) (TryExcept '[] a)
_TryExcept =
  prism
    (\(MkTryExcept a b c d e f g) ->
       CompoundStatement $
       TryExcept a b c d (view _Except <$> e) (view _Else <$> f) (view _Finally <$> g))
    (\case
        CompoundStatement (TryExcept a b c d e f g) ->
          Right $
          MkTryExcept a b c d
            (view (from _Except) <$> e)
            (view (from _Else) <$> f)
            (view (from _Finally) <$> g)
        a -> Left $ a ^. unvalidated)

_TryFinally :: Prism (Statement v a) (Statement '[] a) (TryFinally v a) (TryFinally '[] a)
_TryFinally =
  prism
    (\(MkTryFinally a b c d e) ->
       CompoundStatement $ (\(x, y, z) -> TryFinally a b c d x y z) (e ^. _Finally))
    (\case
        CompoundStatement (TryFinally a b c d e f g) ->
          Right $ MkTryFinally a b c d ((e, f, g) ^. from _Finally)
        a -> Left $ a ^. unvalidated)

_For :: Prism (Statement v a) (Statement '[] a) (For v a) (For '[] a)
_For =
  prism
    (\(MkFor a b c d e f g h i) ->
       CompoundStatement (For a b c d e f g h (view _Else <$> i)))
    (\case
        CompoundStatement (For a b c d e f g h i) ->
          Right $ MkFor a b c d e f g h (view (from _Else) <$> i)
        a -> Left $ a ^. unvalidated)

_Call :: Prism (Expr v a) (Expr '[] a) (Call v a) (Call '[] a)
_Call =
  prism
    (\(MkCall a b c d e) -> Call a b c d e)
    (\case
        Call a b c d e -> Right $ MkCall a b c d e
        a -> Left $ a ^. unvalidated)

_ClassDef :: Prism (Statement v a) (Statement '[] a) (ClassDef v a) (ClassDef '[] a)
_ClassDef =
  prism
    (\(MkClassDef a b c d e f g) -> CompoundStatement $ ClassDef a b c d e f g)
    (\case
        CompoundStatement (ClassDef a b c d e f g) -> Right $ MkClassDef a b c d e f g
        a -> Left $ a ^. unvalidated)

_With :: Prism (Statement v a) (Statement '[] a) (With v a) (With '[] a)
_With =
  prism
    (\(MkWith a b c d e f) -> CompoundStatement $ With a b c d e f)
    (\case
        CompoundStatement (With a b c d e f) -> Right $ MkWith a b c d e f
        a -> Left $ a ^. unvalidated)

_Ident :: Prism (Expr v a) (Expr '[] a) (Ident v a) (Ident '[] a)
_Ident =
  prism
    (\a -> Ident a)
    (\case
        Ident a -> Right a
        a -> Left $ a ^. unvalidated)

_Indent :: HasIndents s => Traversal' (s '[] a) [Whitespace]
_Indent = _Indents.indentsValue.traverse.indentWhitespaces

noIndents :: HasIndents s => Fold (s '[] a) (s '[] a)
noIndents f s = f $ s & _Indents.indentsValue .~ []

class HasIndents s where
  _Indents :: Traversal' (s '[] a) (Indents a)

instance HasIndents Fundef where
  _Indents fun (MkFundef a b c d e f g h i j k) =
    (\b' c' -> MkFundef a b' c' d e f g h i j) <$>
    (traverse._Indents) fun b <*>
    fun c <*>
    _Indents fun k

instance HasIndents For where
  _Indents fun (MkFor a b c d e f g h i) =
    (\b' -> MkFor a b' c d e f g) <$>
    fun b <*>
    _Indents fun h <*>
    (traverse._Indents) fun i

instance HasIndents TryFinally where
  _Indents fun (MkTryFinally a b c d e) =
    (\b' -> MkTryFinally a b' c) <$>
    fun b <*>
    _Indents fun d <*>
    _Indents fun e

instance HasIndents TryExcept where
  _Indents fun (MkTryExcept a b c d e f g) =
    (\b' -> MkTryExcept a b' c) <$>
    fun b <*>
    _Indents fun d <*>
    (traverse._Indents) fun e <*>
    (traverse._Indents) fun f <*>
    (traverse._Indents) fun g

instance HasIndents Except where
  _Indents fun (MkExcept a b c d) =
    (\a' -> MkExcept a' b c) <$>
    fun a <*>
    _Indents fun d

instance HasIndents Finally where
  _Indents fun (MkFinally a b c) =
    (\a' -> MkFinally a' b) <$>
    fun a <*>
    _Indents fun c

instance HasIndents If where
  _Indents fun (MkIf a b c d e f g) =
    (\b' -> MkIf a b' c d) <$>
    fun b <*>
    _Indents fun e <*>
    (traverse._Indents) fun f <*>
    (traverse._Indents) fun g

instance HasIndents While where
  _Indents fun (MkWhile a b c d e) =
    (\b' -> MkWhile a b' c d) <$>
    fun b <*>
    _Indents fun e

instance HasIndents Elif where
  _Indents fun (MkElif a b c d) =
    (\a' -> MkElif a' b c) <$>
    fun a <*>
    _Indents fun d

instance HasIndents Else where
  _Indents f (MkElse a b c) = MkElse <$> f a <*> pure b <*> _Indents f c

instance HasIndents Statement where
  _Indents f (SmallStatements idnt a b c d) =
    (\idnt' -> SmallStatements idnt' a b c d) <$> f idnt
  _Indents f (CompoundStatement c) = CompoundStatement <$> _Indents f c

instance HasIndents Block where
  _Indents = _Statements._Indents

instance HasIndents Suite where
  _Indents _ (SuiteOne a b c d) = pure $ SuiteOne a b c d
  _Indents f (SuiteMany a b c d e) = SuiteMany a b c d <$> _Indents f e

instance HasIndents Decorator where
  _Indents fun (Decorator a b c d e f) =
    (\b' -> Decorator a b' c d e f) <$>
    fun b

instance HasIndents ClassDef where
  _Indents fun (MkClassDef a b c d e f g) =
    (\b' c' -> MkClassDef a b' c' d e f) <$>
    (traverse._Indents) fun b <*>
    fun c <*>
    _Indents fun g

instance HasIndents With where
  _Indents fun (MkWith a b c d e f) =
    (\b' -> MkWith a b' c d e) <$>
    fun b <*>
    _Indents fun f

instance HasIndents CompoundStatement where
  _Indents fun s =
    case s of
      Fundef a decos idnt asyncWs b c d e f g h ->
        (\decos' idnt' -> Fundef a decos' idnt' asyncWs b c d e f g) <$>
        traverse (_Indents fun) decos <*>
        fun idnt <*>
        _Indents fun h
      If a idnt b c d elifs e ->
        (\idnt' -> If a idnt' b c) <$>
        fun idnt <*>
        _Indents fun d <*>
        traverse
          (\(idnt, a, b, c) ->
             (\idnt'  -> (,,,) idnt' a b) <$>
             fun idnt <*>
             _Indents fun c)
          elifs <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$>
             fun idnt <*>
             _Indents fun b)
          e
      While a idnt b c d ->
        (\idnt' -> While a idnt' b c) <$>
        fun idnt <*>
        _Indents fun d
      TryExcept a idnt b c d e f ->
        (\idnt' -> TryExcept a idnt' b) <$>
        fun idnt <*>
        _Indents fun c <*>
        traverse
          (\(idnt, a, b, c) ->
             (\idnt' -> (,,,) idnt' a b) <$>
             fun idnt <*>
             _Indents fun c)
          d <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$>
             fun idnt <*>
             _Indents fun b)
          e <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$>
             fun idnt <*>
             _Indents fun b)
          f
      TryFinally a idnt b c idnt2 d e ->
        (\idnt' c' idnt2' -> TryFinally a idnt' b c' idnt2' d) <$>
        fun idnt <*>
        _Indents fun c <*>
        fun idnt2 <*>
        _Indents fun e
      For a idnt asyncWs b c d e f g ->
        (\idnt' -> For a idnt' asyncWs b c d e) <$>
        fun idnt <*>
        _Indents fun f <*>
        traverse
          (\(idnt, a, b) ->
             (\idnt' -> (,,) idnt' a) <$>
             fun idnt <*>
             _Indents fun b)
          g
      ClassDef a decos idnt b c d e ->
        (\decos' idnt' -> ClassDef a decos' idnt' b c d) <$>
        traverse (_Indents fun) decos <*>
        fun idnt <*>
        _Indents fun e
      With a b asyncWs c d e ->
        (\b' -> With a b' asyncWs c d) <$>
        fun b <*>
        _Indents fun e

class HasNewlines s where
  _Newlines :: Traversal' (s v a) Newline

instance HasNewlines Block where
  _Newlines f (Block a b c) =
    Block <$>
    (traverse._4) f a <*>
    _Newlines f b <*>
    (traverse._Right._Newlines) f c

instance HasNewlines Suite where
  _Newlines _ (SuiteOne a b c d) = pure $ SuiteOne a b c d
  _Newlines f (SuiteMany a b c d e) = SuiteMany a b c <$> f d <*> _Newlines f e

instance HasNewlines Decorator where
  _Newlines fun (Decorator a b c d e f) =
    Decorator a b c d e <$> fun f

instance HasNewlines CompoundStatement where
  _Newlines fun s =
    case s of
      Fundef ann decos idnt asyncWs ws1 name ws2 params ws3 mty s ->
        (\decos' -> Fundef ann decos' idnt asyncWs ws1 name ws2 params ws3 mty) <$>
        traverse (_Newlines fun) decos <*>
        _Newlines fun s
      If idnt ann ws1 cond s elifs els ->
        If idnt ann ws1 cond <$>
        _Newlines fun s <*>
        traverseOf (traverse._4._Newlines) fun elifs <*>
        traverseOf (traverse._3._Newlines) fun els
      While idnt ann ws1 cond s ->
        While idnt ann ws1 cond <$> _Newlines fun s
      TryExcept idnt a b c f k l ->
        TryExcept idnt a b <$> _Newlines fun c <*>
        traverseOf (traverse._4._Newlines) fun f <*>
        traverseOf (traverse._3._Newlines) fun k <*>
        traverseOf (traverse._3._Newlines) fun l
      TryFinally idnt a b c idnt2 f g ->
        TryFinally idnt a b <$> _Newlines fun c <*> pure idnt2 <*>
        pure f <*> _Newlines fun g
      For idnt a asyncWs b c d e f g ->
        For idnt a asyncWs b c d e <$> _Newlines fun f <*> (traverse._3._Newlines) fun g
      ClassDef a decos idnt b c d e ->
        (\decos' -> ClassDef a decos' idnt b (coerce c) (coerce d)) <$>
        traverse (_Newlines fun) decos <*>
        _Newlines fun e
      With a b asyncWs c d e -> With a b asyncWs c (coerce d) <$> _Newlines fun e

instance HasNewlines Statement where
  _Newlines f (CompoundStatement c) =
    CompoundStatement <$> _Newlines f c
  _Newlines _ (SmallStatements idnts s ss sc cmt) =
    pure $ SmallStatements idnts s ss sc cmt

instance HasNewlines Module where
  _Newlines f = go
    where
      go ModuleEmpty = pure ModuleEmpty
      go (ModuleBlankFinal a b c) = pure $ ModuleBlankFinal a b c
      go (ModuleBlank a b c d e) =
        ModuleBlank a b c <$> f d <*> go e
      go (ModuleStatement a b) =
        ModuleStatement <$> _Newlines f a <*> go b

assignTargets :: Traversal (Expr v a) (Expr '[] a) (Ident v a) (Ident '[] a)
assignTargets f e =
  case e of
    List a b c d -> (\c' -> List a b c' d) <$> (traverse.traverse._Exprs.assignTargets) f c
    Parens a b c d -> (\c' -> Parens a b c' d) <$> assignTargets f c
    Ident a -> Ident <$> f a
    Tuple a b c d ->
      (\b' d' -> Tuple a b' c d') <$>
      (_Exprs.assignTargets) f b <*>
      (traverse.traverse._Exprs.assignTargets) f d
    Unit{} -> pure $ e ^. unvalidated
    Lambda{} -> pure $ e ^. unvalidated
    Yield{} -> pure $ e ^. unvalidated
    YieldFrom{} -> pure $ e ^. unvalidated
    Ternary{} -> pure $ e ^. unvalidated
    ListComp{} -> pure $ e ^. unvalidated
    Deref{} -> pure $ e ^. unvalidated
    Subscript{} -> pure $ e ^. unvalidated
    Call{} -> pure $ e ^. unvalidated
    None{} -> pure $ e ^. unvalidated
    Ellipsis{} -> pure $ e ^. unvalidated
    BinOp{} -> pure $ e ^. unvalidated
    UnOp{} -> pure $ e ^. unvalidated
    Int{} -> pure $ e ^. unvalidated
    Float{} -> pure $ e ^. unvalidated
    Imag{} -> pure $ e ^. unvalidated
    Bool{} -> pure $ e ^. unvalidated
    String{} -> pure $ e ^. unvalidated
    Not{} -> pure $ e ^. unvalidated
    DictComp{} -> pure $ e ^. unvalidated
    Dict{} -> pure $ e ^. unvalidated
    SetComp{} -> pure $ e ^. unvalidated
    Set{} -> pure $ e ^. unvalidated
    Generator{} -> pure $ e ^. unvalidated
    Await{} -> pure $ e ^. unvalidated
