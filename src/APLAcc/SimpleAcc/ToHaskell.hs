module APLAcc.SimpleAcc.ToHaskell (
  toHs,
  OutputOpts(..), defaultOpts,
) where

import Prelude hiding (exp)

import Language.Haskell.Exts.Syntax as Hs
import Language.Haskell.Exts.SrcLoc (noLoc)
import Language.Haskell.Exts.Pretty (prettyPrint)

import qualified APLAcc.SimpleAcc.AST as A

data OutputOpts = ToHsOpts
  { toCUDA :: Bool
  , tailInput :: Bool
  , runProgram :: Bool
  , verbose :: Bool
  }

defaultOpts = ToHsOpts
  { toCUDA = False
  , tailInput = False
  , runProgram = False
  , verbose = False
  }

toHs :: OutputOpts -> A.Program -> String
toHs opts = prettyPrint . outputProgram opts

instance Show A.Type where
  show = prettyPrint . outputType

instance Show A.Name where
  show = prettyPrint . name

instance Show A.QName where
  show = prettyPrint . qname

instance Show A.Exp where
  show = prettyPrint . outputExp


qualAcc :: Name -> QName
qualAcc = UnQual

qualPrelude :: Name -> QName
qualPrelude = Qual (ModuleName "P")

name :: A.Name -> Name
name (A.Ident n) = Ident n
name (A.Symbol n) = Symbol n

qname :: A.QName -> QName
qname (A.UnQual n)     = UnQual $ name n
qname (A.Prelude (A.Symbol "+")) = UnQual $ Symbol "+"
qname (A.Prelude (A.Symbol "-")) = UnQual $ Symbol "-"
qname (A.Prelude (A.Symbol "*")) = UnQual $ Symbol "*"
qname (A.Prelude (A.Symbol "/")) = UnQual $ Symbol "/"
qname (A.Prelude n)    = Qual (ModuleName "P") $ name n
qname (A.Accelerate n) = UnQual $ name n
qname (A.Primitive n)  = Qual (ModuleName "Prim") $ name n
qname (A.Backend n)  = Qual (ModuleName "Backend") $ name n

infixOp :: A.QName -> QOp
infixOp = QVarOp . qname

io     = TyApp $ TyCon $ qname $ A.Prelude $ A.Ident "IO"
acc    = TyApp $ TyCon $ qname $ A.Accelerate $ A.Ident "Acc"
exp    = TyApp $ TyCon $ qname $ A.Accelerate $ A.Ident "Exp"
scalar = TyApp $ TyCon $ qname $ A.Accelerate $ A.Ident "Scalar"
vector = TyApp $ TyCon $ qname $ A.Accelerate $ A.Ident "Vector"
array d = TyApp (TyApp (TyCon $ qname $ A.Accelerate $ A.Ident "Array") d)
dim n  = TyCon $ qname $ A.Accelerate $ A.Ident $ "DIM" ++ show n
int    = TyCon $ qname $ A.Prelude $ A.Ident "Int"
double = TyCon $ qname $ A.Prelude $ A.Ident "Double"
bool   = TyCon $ qname $ A.Prelude $ A.Ident "Bool"
char   = TyCon $ qname $ A.Prelude $ A.Ident "Char"

snocList :: [Exp] -> Exp
snocList es =
  foldl (\e e' -> InfixApp e (infixOp $ A.Accelerate $ A.Symbol ":.") e')
        (Var $ qname $ A.Accelerate $ A.Ident "Z")
        (map typSigInt es)
  where typSigInt e = ExpTypeSig noLoc e (exp int)

snocPat :: [Integer] -> Pat
snocPat ns =
  foldl (\e e' -> PInfixApp e (qname $ A.Accelerate $ A.Symbol ":.") e')
        (PApp (qname $ A.Accelerate $ A.Ident "Z") [])
        (map typSigInt ns)
  where typSigInt n = PVar $ Ident $ "a" ++ show n


outputProgram :: OutputOpts -> A.Program -> Module
outputProgram opts stmts =
  Module noLoc (ModuleName "Main") [] Nothing Nothing imports [progSig, prog, main]
  where backend = if toCUDA opts
                  then "Data.Array.Accelerate.CUDA"
                  else "Data.Array.Accelerate.Interpreter"
        imports =
          [ ImportDecl { importLoc       = noLoc
                       , importModule    = ModuleName "Prelude"
                       , importQualified = True
                       , importSrc       = False
                       , importSafe      = False
                       , importPkg       = Nothing
                       , importAs        = Just $ ModuleName "P"
                       , importSpecs     = Nothing }
          , ImportDecl { importLoc       = noLoc
                       , importModule    = ModuleName "Prelude"
                       , importQualified = False
                       , importSrc       = False
                       , importSafe      = False
                       , importPkg       = Nothing
                       , importAs        = Nothing
                       , importSpecs     = Just (False, map (IAbs . Symbol) ["+", "-", "*", "/"]) }
          , ImportDecl { importLoc       = noLoc
                       , importModule    = ModuleName "Data.Array.Accelerate"
                       , importQualified = False
                       , importSrc       = False
                       , importSafe      = False
                       , importPkg       = Nothing
                       , importAs        = Nothing
                       , importSpecs     = Nothing }
          , ImportDecl { importLoc       = noLoc
                       , importModule    = ModuleName backend
                       , importQualified = True
                       , importSrc       = False
                       , importSafe      = False
                       , importPkg       = Nothing
                       , importAs        = Just $ ModuleName "Backend"
                       , importSpecs     = Nothing }
          , ImportDecl { importLoc       = noLoc
                       , importModule    = ModuleName "APLAcc.Primitives"
                       , importQualified = True
                       , importSrc       = False
                       , importSafe      = False
                       , importPkg       = Nothing
                       , importAs        = Just $ ModuleName "Prim"
                       , importSpecs     = Nothing }
          ]
        -- Assume result is always scalar double for now
        progSig = TypeSig noLoc [Ident "program"] $ io $ acc (scalar double)
        prog = FunBind
          [Match noLoc (Ident "program") [] Nothing
                 (UnGuardedRhs $ Do $ map outputStmt stmts) (BDecls [])]
        main = FunBind
          [Match noLoc (Ident "main") [] Nothing
                 (UnGuardedRhs mainBody) (BDecls [])]
        mainBody =
          let bind e1 e2 = InfixApp e1 (infixOp $ A.Prelude $ A.Symbol ">>=") e2
              dot e1 e2  = InfixApp e1 (infixOp $ A.Prelude $ A.Symbol ".") e2
          in  bind (Var $ UnQual $ Ident "program") $ dot (Var $ qualPrelude $ Ident "print")
                                                          (Var $ Qual (ModuleName "Backend") $ Ident "run")

outputStmt :: A.Stmt -> Stmt
outputStmt (A.LetStmt ident typ e) =
  let e' = case e of
              (A.TypSig _ _) -> outputExp e
              _              -> ExpTypeSig noLoc (outputExp e) (outputType typ)
  in  LetStmt (BDecls [ PatBind noLoc (PVar $ Ident ident) (UnGuardedRhs e') (BDecls []) ])
outputStmt (A.Bind ident typ e) = Generator noLoc (PVar $ Ident ident) (outputExp e)
outputStmt (A.Return True e) = Qualifier $ outputExp e
outputStmt (A.Return False e) = Qualifier $ App (Var $ qualPrelude $ Ident "return") (outputExp e)

outputExp :: A.Exp -> Exp
outputExp (A.Var n) = Var $ qname n 
outputExp (A.I i) = Lit $ Int i
outputExp (A.D d) = Lit $ Frac $ toRational d
outputExp (A.B True) = Con $ qualPrelude $ Ident "True"
outputExp (A.B False) = Con $ qualPrelude $ Ident "False"
outputExp (A.C c) = Lit $ Char c
outputExp (A.Shape is) = outputExp $ snoc is
  where snoc es = A.InfixApp (A.Accelerate $ A.Symbol ":.") ((A.Var $ A.Accelerate $ A.Ident "Z") : map toInt es)
        toInt i = A.TypSig (A.I i) (A.Plain A.IntT)
outputExp (A.TypSig e t) = ExpTypeSig noLoc (outputExp e) (outputType t)
outputExp (A.Neg e) = NegApp $ outputExp e
outputExp (A.List es) = List $ map outputExp es
outputExp (A.Tuple es) = Tuple Boxed $ map outputExp es
outputExp (A.InfixApp n [e]) = outputExp e
outputExp (A.InfixApp n (e1:e2:es)) =
  foldl op (op (Paren $ outputExp e1) (Paren $ outputExp e2)) (map (Paren . outputExp) es)
  where op = flip InfixApp (infixOp n)
outputExp (A.InfixApp n []) = error "invalid infix application"
outputExp (A.App n es) = foldl App (Var $ qname n) (map outputExp es)
outputExp (A.Let ident typ e1 e2) =
  let e1' = case e1 of
              (A.TypSig _ _) -> outputExp e1
              _              -> ExpTypeSig noLoc (outputExp e1) (outputType typ)
  in Let (BDecls [ PatBind noLoc (PVar $ Ident ident) (UnGuardedRhs e1') (BDecls []) ])
         (outputExp e2)
outputExp (A.Fn ident _ e) =
  Lambda noLoc [PVar $ Ident ident] (outputExp e)
outputExp (A.IdxFn perm) =
  Lambda noLoc [PVar $ Ident "a"] $
    Let (BDecls [PatBind noLoc pat (UnGuardedRhs unlift) (BDecls [])]) $
       lift $ snocList $ map (Var . UnQual . Ident . \n -> "a" ++ show n) perm
  where pat = snocPat $ take (length perm) [1..]
        unlift = App (Var $ qualAcc $ Ident "unlift") (Var $ UnQual $ Ident "a")
        lift = App (Var $ qualAcc $ Ident "lift")

outputType :: A.Type -> Type
outputType (A.Exp btyp) = exp (outputBType btyp)
outputType (A.Acc r btyp) = acc $ array (dim r) (outputBType btyp)
outputType (A.Plain btyp) = outputBType btyp
outputType (A.IO_ typ) = io $ outputType typ

outputBType :: A.BType -> Type
outputBType A.IntT = int
outputBType A.DoubleT = double
outputBType A.BoolT = bool
outputBType A.CharT = char
