{-# language GeneralizedNewtypeDeriving, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module Language.Python.Internal.Render where

import Control.Lens.Getter
import Control.Lens.Wrapped
import Data.Char (ord)
import Data.Maybe
import Data.Semigroup (Semigroup(..))
import Language.Python.Internal.Syntax

bracket :: String -> String
bracket a = "(" <> a <> ")"

escapeChars :: [Char]
escapeChars = "\\\'\"\a\b\f\n\r\t\v"

intToHex :: Int -> String
intToHex n = go n []
  where
    go 0 = (++"0")
    go 1 = (++"1")
    go 2 = (++"2")
    go 3 = (++"3")
    go 4 = (++"4")
    go 5 = (++"5")
    go 6 = (++"6")
    go 7 = (++"7")
    go 8 = (++"8")
    go 9 = (++"9")
    go 10 = (++"A")
    go 11 = (++"B")
    go 12 = (++"C")
    go 13 = (++"D")
    go 14 = (++"E")
    go 15 = (++"F")
    go b = let (q, r) = quotRem b 16 in go r . go q

renderChar :: Char -> String
renderChar c
  | c `elem` escapeChars = ['\\', c]
  | otherwise =
      let
        shown = show c
      in
        case shown of
          '\'' : '\\' : _ ->
            let
              hex = intToHex (ord c)
            in
              "\\U" ++ replicate (8 - length hex) '0' ++ hex
          _ -> [c]

data Lines a
  = NoLines
  | OneLine a
  | ManyLines a Newline (Lines a)
  deriving (Eq, Show, Functor, Foldable, Traversable)
listToLines :: Newline -> [a] -> Lines a
listToLines _ [] = NoLines
listToLines _ [a] = OneLine a
listToLines nl (a:as) = ManyLines a nl $ listToLines nl as

endWith :: Newline -> Lines a -> Lines a
endWith nl NoLines = NoLines
endWith nl (OneLine a) = ManyLines a nl NoLines
endWith nl (ManyLines a nl' as) =
  ManyLines
    a
    (case as of; NoLines -> nl; _ -> nl')
    (case as of; NoLines -> NoLines; _ -> endWith nl as)

renderLines :: Lines String -> String
renderLines NoLines = ""
renderLines (OneLine a) = a
renderLines (ManyLines a nl ls) = a <> renderNewline nl <> renderLines ls

instance Semigroup a => Semigroup (Lines a) where
  NoLines <> a = a
  OneLine a <> NoLines = OneLine a
  OneLine a <> OneLine b = OneLine (a <> b)
  OneLine a <> ManyLines b nl ls = ManyLines (a <> b) nl ls
  ManyLines a nl ls <> b = ManyLines a nl (ls <> b)

instance Semigroup a => Monoid (Lines a) where
  mempty = NoLines
  mappend = (<>)

renderAnyWhitespace :: Either Newline Whitespace -> String
renderAnyWhitespace (Left nl) = renderNewline nl
renderAnyWhitespace (Right sp) = renderWhitespace sp

renderWhitespace :: Whitespace -> String
renderWhitespace Space = " "
renderWhitespace Tab = "\t"
renderWhitespace (Continued nl ws) = "\\" <> renderNewline nl <> foldMap renderWhitespace ws
renderWhitespace (Newline nl) = renderNewline nl

renderNewline :: Newline -> String
renderNewline CR = "\r"
renderNewline LF = "\n"
renderNewline CRLF = "\r\n"

renderCommaSep :: (a -> String) -> CommaSep a -> String
renderCommaSep _ CommaSepNone = mempty
renderCommaSep f (CommaSepOne a) = f a
renderCommaSep f (CommaSepMany a ws2 c) =
  f a <> "," <>
  foldMap renderWhitespace ws2 <>
  renderCommaSep f c

renderCommaSep1 :: (a -> String) -> CommaSep1 a -> String
renderCommaSep1 f (CommaSepOne1 a) = f a
renderCommaSep1 f (CommaSepMany1 a ws2 c) =
  f a <> "," <>
  foldMap renderWhitespace ws2 <>
  renderCommaSep1 f c

renderCommaSep1' :: (a -> String) -> CommaSep1' a -> String
renderCommaSep1' f (CommaSepOne1' a b) =
  f a <>
  foldMap (\x -> "," <> foldMap renderWhitespace x) b
renderCommaSep1' f (CommaSepMany1' a ws2 c) =
  f a <> "," <> foldMap renderWhitespace ws2 <>
  renderCommaSep1' f c

renderIdent :: Ident v a -> String
renderIdent = _identValue

renderExpr :: Expr v a -> String
renderExpr (Parens _ ws1 e ws2) =
  "(" <> foldMap renderWhitespace ws1 <>
  renderExpr e <> ")" <> foldMap renderWhitespace ws2
renderExpr (Bool _ b ws) = show b <> foldMap renderWhitespace ws
renderExpr (Negate _ ws expr) =
  "-" <> foldMap renderWhitespace ws <>
    case expr of
      BinOp _ _ Exp{} _ -> renderExpr expr
      BinOp{} -> "(" <> renderExpr expr <> ")"
      _ -> renderExpr expr
renderExpr (String _ strType b ws) =
  let
    quote =
      case strType of
        ShortSingle -> "'"
        ShortDouble -> "\""
        LongSingle -> "'''"
        LongDouble -> "\"\"\""
  in
    quote <> foldMap renderChar b <> quote <> foldMap renderWhitespace ws
renderExpr (Int _ n ws) = show n <> foldMap renderWhitespace ws
renderExpr (Ident _ name) = renderIdent name
renderExpr (List _ ws1 exprs ws2) =
  "[" <> foldMap renderWhitespace ws1 <>
  renderCommaSep renderExpr exprs <>
  "]" <> foldMap renderWhitespace ws2
renderExpr (Call _ expr ws args ws2) =
  (case expr of
     Int _ n _ | n < 0 -> "(" <> renderExpr expr <> ")"
     BinOp {} -> "(" <> renderExpr expr <> ")"
     Tuple {} -> "(" <> renderExpr expr <> ")"
     _ -> renderExpr expr) <>
  "(" <> foldMap renderWhitespace ws <> foldMap renderArg args <>
  ")" <> foldMap renderWhitespace ws2
renderExpr (Deref _ expr ws name) =
  (case expr of
    Int{} -> "(" <> renderExpr expr <> ")"
    BinOp{} -> "(" <> renderExpr expr <> ")"
    Tuple{} -> "(" <> renderExpr expr <> ")"
    _ -> renderExpr expr) <>
  "." <>
  foldMap renderWhitespace ws <>
  renderIdent name
renderExpr (None _ ws) = "None" <> foldMap renderWhitespace ws
renderExpr (BinOp _ e1 op e2) =
  (if shouldBracketLeft op e1 then bracket else id) (renderExpr e1) <>
  renderBinOp op <>
  (if shouldBracketRight op e2 then bracket else id) (renderExpr e2)
renderExpr (Tuple _ a ws c) =
  bracketTuple a (renderExpr a) <> "," <> foldMap renderWhitespace ws <>
  foldMap
    (renderCommaSep1' (\b -> bracketTuple b $ renderExpr b))
    c
  where
    bracketTuple a =
      case a of
        Tuple{} -> bracket
        _ -> id

renderModuleName :: ModuleName v a -> String
renderModuleName (ModuleNameOne _ s) = renderIdent s
renderModuleName (ModuleNameMany _ n ws1 ws2 rest) =
  renderIdent n <> foldMap renderWhitespace ws1 <> "." <> foldMap renderWhitespace ws2 <>
  renderModuleName rest

renderDot :: Dot -> String
renderDot (Dot ws) = "." <> foldMap renderWhitespace ws

renderRelativeModuleName :: RelativeModuleName v a -> String
renderRelativeModuleName (RelativeWithName ds mn) =
  foldMap renderDot ds <> renderModuleName mn
renderRelativeModuleName (Relative ds) = foldMap renderDot ds

renderAs1 :: (a -> String) -> As1 a -> String
renderAs1 f (As1 ws1 ws2 a) =
  foldMap renderWhitespace ws1 <> "as" <> foldMap renderWhitespace ws2 <> f a

renderImportTargets :: ImportTargets v a -> String
renderImportTargets ImportAll = "*"
renderImportTargets (ImportSome ts) =
  renderCommaSep1 (\(mn, mAs) -> renderIdent mn <> foldMap (renderAs1 renderIdent) mAs) ts
renderImportTargets (ImportSomeParens ws1 ts ws2) =
  "(" <> foldMap renderWhitespace ws1 <>
  renderCommaSep1' (\(mn, mAs) -> renderIdent mn <> foldMap (renderAs1 renderIdent) mAs) ts <>
  ")" <> foldMap renderWhitespace ws2

renderSmallStatement :: SmallStatement v a -> String
renderSmallStatement (Return _ ws expr) =
  "return" <> foldMap renderWhitespace ws <> renderExpr expr
renderSmallStatement (Expr _ expr) = renderExpr expr
renderSmallStatement (Assign _ lvalue ws1 ws2 rvalue) =
  renderExpr lvalue <> foldMap renderWhitespace ws1 <> "=" <>
  foldMap renderWhitespace ws2 <> renderExpr rvalue
renderSmallStatement (Pass _) = "pass"
renderSmallStatement (Break _) = "break"
renderSmallStatement (Global _ ws ids) =
  "global" <> foldMap renderWhitespace ws <> renderCommaSep1 renderIdent ids
renderSmallStatement (Nonlocal _ ws ids) =
  "nonlocal" <> foldMap renderWhitespace ws <> renderCommaSep1 renderIdent ids
renderSmallStatement (Del _ ws ids) =
  "del" <> foldMap renderWhitespace ws <> renderCommaSep1 renderIdent ids
renderSmallStatement (Import _ ws ns) =
  "import" <> foldMap renderWhitespace ws <>
  renderCommaSep1
    (\(mn, mAs) -> renderModuleName mn <> foldMap (renderAs1 renderIdent) mAs) ns
renderSmallStatement (From _ ws1 name ws3 ns) =
  "from" <> foldMap renderWhitespace ws1 <>
  renderRelativeModuleName name <> "import" <> foldMap renderWhitespace ws3 <>
  renderImportTargets ns

renderCompoundStatement :: CompoundStatement v a -> Lines String
renderCompoundStatement (Fundef _ ws1 name ws2 params ws3 ws4 nl body) =
  ManyLines firstLine nl restLines
  where
    firstLine =
      "def" <> foldMap renderWhitespace ws1 <> renderIdent name <>
      foldMap renderWhitespace ws2 <> renderParams params <>
      foldMap renderWhitespace ws3 <> ":" <> foldMap renderWhitespace ws4
    restLines =
      foldMap
        (\(_, a, b) -> (foldMap renderWhitespace a <>) <$> renderStatement b)
        (view _Wrapped body)
renderCompoundStatement (If _ ws1 expr ws2 ws3 nl body body') =
  ManyLines firstLine nl restLines
  where
    firstLine =
      "if" <> foldMap renderWhitespace ws1 <>
      renderExpr expr <> foldMap renderWhitespace ws2 <> ":" <>
      foldMap renderWhitespace ws3
    restLines =
      foldMap
        (\(_, a, b) -> (foldMap renderWhitespace a <>) <$> renderStatement b)
        (view _Wrapped body) <>
      fromMaybe mempty elseLines
    elseLines =
      ManyLines <$>
      fmap
        (\(ws4, ws5, _, _) ->
           "else" <> foldMap renderWhitespace ws4 <> ":" <>
           foldMap renderWhitespace ws4)
        body' <*>
      fmap (\(_, _, nl2, _) -> nl2) body' <*>
      fmap
        (\(_, _, _, body'') ->
           foldMap
             (\(_, a, b) -> (foldMap renderWhitespace a <>) <$> renderStatement b)
             (view _Wrapped body''))
        body'
renderCompoundStatement (While _ ws1 expr ws2 ws3 nl body) =
  ManyLines
    ("while" <> foldMap renderWhitespace ws1 <> renderExpr expr <>
     foldMap renderWhitespace ws2 <> ":" <> foldMap renderWhitespace ws3)
    nl
    (foldMap
       (\(_, a, b) -> (foldMap renderWhitespace a <>) <$> renderStatement b)
       (view _Wrapped body))

renderStatement :: Statement v a -> Lines String
renderStatement (CompoundStatement c) = renderCompoundStatement c
renderStatement (SmallStatements s ss sc nl) =
  ManyLines
  (renderSmallStatement s <>
   foldMap
     (\(a, b, c) ->
        foldMap renderWhitespace a <> ";" <>
        foldMap renderWhitespace b <>
        renderSmallStatement c)
     ss <>
   foldMap
     (\(a, b) -> foldMap renderWhitespace a <> ";" <> foldMap renderWhitespace b)
     sc)
  nl
  NoLines

renderArg :: Arg v a -> String
renderArg (PositionalArg _ expr) = renderExpr expr
renderArg (KeywordArg _ name ws2 expr) =
  renderIdent name <> "=" <>
  foldMap renderWhitespace ws2 <> renderExpr expr

renderParams :: CommaSep (Param v a) -> String
renderParams a = "(" <> renderCommaSep go a <> ")"
  where
    go (PositionalParam _ name) = renderIdent name
    go (KeywordParam _ name ws2 expr) =
      renderIdent name <> "=" <>
      foldMap renderWhitespace ws2 <> renderExpr expr

renderBinOp :: BinOp a -> String
renderBinOp (Is _ ws) = "is" <> foldMap renderWhitespace ws
renderBinOp (Plus _ ws) = "+" <> foldMap renderWhitespace ws
renderBinOp (Minus _ ws) = "-" <> foldMap renderWhitespace ws
renderBinOp (Multiply _ ws) = "*" <> foldMap renderWhitespace ws
renderBinOp (Divide _ ws) = "/" <> foldMap renderWhitespace ws
renderBinOp (Exp _ ws) = "**" <> foldMap renderWhitespace ws
renderBinOp (BoolAnd _ ws) = "and" <> foldMap renderWhitespace ws
renderBinOp (BoolOr _ ws) = "or" <> foldMap renderWhitespace ws
renderBinOp (Equals _ ws) = "==" <> foldMap renderWhitespace ws

renderModule :: Module v a -> String
renderModule (Module ms) =
  foldMap
    (either
       (\(a, b) -> foldMap renderWhitespace a <> renderNewline b)
       (renderLines . renderStatement))
    ms
