{-| Module      :  CoreUtils
    License     :  GPL

    Maintainer  :  helium@cs.uu.nl
    Stability   :  experimental
    Portability :  portable
-}

module Helium.CodeGeneration.CoreUtils
    (   custom, customStrategy
    ,   stringToCore, coreList
    ,   let_, if_, app_, letrec_
    ,   cons, nil
    ,   var, decl
    ,   float, packedString
    ,   toplevelType, declarationType, localDeclarationType
    ,   toCoreType, toCoreTypeNotQuantified, typeToCoreType
    ,   addLambdas, TypeClassContext(..)
    ) where
import Debug.Trace
import Top.Types as Top
import Top.Solver(SolveResult(..))
import Top.Types.Substitution(FixpointSubstitution, lookupInt)
import Lvm.Core.Expr
import Lvm.Core.Type as Core
import Lvm.Common.Id
import Lvm.Core.Utils
import Data.Char
import Data.Maybe
import Lvm.Common.Byte(bytesFromString)
import qualified Lvm.Core.Expr as Core
import qualified Data.Map as M
import Helium.ModuleSystem.ImportEnvironment
import Helium.Syntax.UHA_Syntax
import Helium.Syntax.UHA_Utils
import Helium.Utils.Utils

infixl `app_`

custom :: String -> String -> Custom
custom sort text =
    CustomDecl
        (DeclKindCustom (idFromString sort))
        [CustomBytes (bytesFromString text)]


customStrategy :: String -> Decl a
customStrategy text =
    DeclCustom    
        { declName = idFromString ""
        , declAccess = Defined { accessPublic = True }
        , declKind = DeclKindCustom (idFromString "strategy")
        , declCustoms = [custom "strategy" text]
        }

app_ :: Expr -> Expr -> Expr
app_ f x = Ap f x

let_ :: Id -> Core.Type -> Expr -> Expr -> Expr
let_ x t e b = Let (NonRec (Bind (Variable x t) e)) b

letrec_ :: [CoreDecl] -> Expr -> Expr
letrec_ bs e = 
    Let 
        (Rec 
            [ Bind (Variable ident t) expr
            | DeclValue { declName = ident, declType = t, valueValue = expr } <- bs
            ]
        ) 
        e

-- Function "if_" builds a Core expression of the following form
-- let! guardId = <guardExpr> in 
-- match guardId 
--   True -> <thenExpr>
--   _    -> <elseExpr>
if_ :: Expr -> Expr -> Expr -> Expr
if_ guardExpr thenExpr elseExpr =
    Let 
        (Strict (Bind (Variable guardId typeBool) guardExpr))
        (Match guardId
            [ Alt (PatCon (ConId trueId) []) thenExpr
            , Alt PatDefault elseExpr
            ]
        )

-- Function "coreList" builds a linked list of the given expressions
-- Example: coreList [e1, e2] ==> 
--   Ap (Ap (Con ":") e1) 
--           (Ap (Ap (Con ":") e2)
--                    (Con "[]")
--           )
coreList :: [Expr] -> Expr
coreList = foldr cons nil

cons :: Expr -> Expr -> Expr
cons x xs = Con (ConId consId) `app_` x `app_` xs

nil :: Expr
nil = Con (ConId nilId)

nilId, consId, trueId, guardId :: Id 
( nilId : consId :  trueId :  guardId : []) =
   map idFromString ["[]", ":", "True", "guard$"]

-- Function "stringToCore" converts a string to a Core expression
stringToCore :: String -> Expr
stringToCore [] = nil
stringToCore [x] = cons (Lit (LitInt (ord x))) nil
stringToCore xs = var "$primPackedToString" `app_` packedString xs

var :: String -> Expr
var x = Var (idFromString x)

--Core.Lit (Core.LitDouble (read @value))   PUSHFLOAT nog niet geimplementeerd
float :: String -> Expr
float f = 
    Core.Ap 
        (Core.Var (idFromString "$primStringToFloat")) 
        ( Core.Lit (Core.LitBytes (bytesFromString f)) )

decl :: Bool -> String -> Core.Type -> Expr -> CoreDecl
decl isPublic x t e = 
    DeclValue 
        { declName = idFromString x
        , declAccess = Defined { accessPublic = isPublic }
        , declType = t
        , valueValue = e
        , declCustoms = []
        }

packedString :: String -> Expr
packedString s = Lit (LitBytes (bytesFromString s))

data TypeClassContext
    = TCCNone
    | TCCClass
    | TCCInstance Id Core.Type

declarationTpScheme :: M.Map NameWithRange Top.TpScheme -> ImportEnvironment -> TypeClassContext -> Name -> Maybe Top.TpScheme
declarationTpScheme fullTypeSchemes _ TCCNone name = M.lookup (NameWithRange name) fullTypeSchemes
declarationTpScheme _ importEnv _ name = M.lookup name (typeEnvironment importEnv)

localDeclarationType :: M.Map NameWithRange Top.TpScheme -> Name -> Core.Type
localDeclarationType fullTypeSchemes name = case M.lookup (NameWithRange name) fullTypeSchemes of
  Just scheme -> toCoreType scheme
  Nothing -> trace ("Could not find type for local variable " ++ getNameName name) Core.TAny

-- Finds the instantiation of a declaration in a type class instance.
-- E.g. Num a => a -> a
-- For a function in an instance for `Num Int` this will return (a, Int)
instantiationInTypeClassInstance :: TypeClassContext -> Top.TpScheme -> Maybe (Id, Core.Type)
instantiationInTypeClassInstance (TCCInstance className instanceType) (Top.Quantification (_, qmap, (Top.Qualification (Predicate _ (Top.TVar typeVar) : _, _))))
  = Just (typeVarToId qmap typeVar, instanceType)
instantiationInTypeClassInstance _ _ = Nothing

declarationType :: M.Map NameWithRange Top.TpScheme -> ImportEnvironment -> TypeClassContext -> Name -> Core.Type
declarationType fullTypeSchemes importEnv context name =
  case declarationTpScheme fullTypeSchemes importEnv context name of
    Just ty ->
      let coreType = toCoreType ty
      in case instantiationInTypeClassInstance context ty of
        Just (typeVar, instanceType) -> Core.typeInstantiate typeVar instanceType coreType
        Nothing -> coreType
    Nothing -> Core.TAny

toCoreType :: Top.TpScheme -> Core.Type
toCoreType (Top.Quantification (tvars, qmap, t)) = foldr addTypeVar t' tvars
  where
    t' = qtypeToCoreType qmap t
    addTypeVar index = Core.TForall (typeVarToId qmap index) Core.KStar

toCoreTypeNotQuantified :: Top.TpScheme -> Core.Type
toCoreTypeNotQuantified (Top.Quantification (_, qmap, t)) = qtypeToCoreType qmap t

typeVarToId :: Top.QuantorMap -> Int -> Id
typeVarToId qmap index = case lookup index qmap of
    Just name -> idFromString name
    _ -> idFromString ("v" ++ show index)

qtypeToCoreType :: Top.QuantorMap -> Top.QType -> Core.Type
qtypeToCoreType qmap (Top.Qualification (q, t)) = foldr addDictArgument (typeToCoreType qmap t) q
  where
    addDictArgument predicate = Core.TAp $ Core.TAp (Core.TCon Core.TConFun) arg
      where
        arg = predicateToCoreType qmap predicate

predicateToCoreType :: Top.QuantorMap -> Top.Predicate -> Core.Type
predicateToCoreType qmap (Top.Predicate className tp) =
    Core.TAp (Core.TCon $ TConTypeClassDictionary $ idFromString className) $ typeToCoreType qmap tp

typeToCoreType :: Top.QuantorMap -> Top.Tp -> Core.Type
typeToCoreType qmap (Top.TVar index) = Core.TVar $ typeVarToId qmap index
typeToCoreType _ (Top.TCon name) = Core.TCon c
  where
    c = case name of
        "->" -> Core.TConFun
        '(':str
          | dropWhile (==',') str == ")" -> Core.TConTuple (length str)
        _ -> Core.TConDataType $ idFromString name
typeToCoreType qmap (Top.TApp t1 t2) = Core.TAp (typeToCoreType qmap t1) (typeToCoreType qmap t2)

toplevelType :: Name -> ImportEnvironment -> Bool -> [Custom]
toplevelType name ie isTopLevel
    | isTopLevel = [custom "type" typeString]
    | otherwise  = []
    where
        typeString = maybe
            (internalError "ToCoreDecl" "Declaration" ("no type found for " ++ getNameName name))
            show
            (M.lookup name (typeEnvironment ie))

addLambdas :: M.Map NameWithRange Top.TpScheme -> ImportEnvironment -> TypeClassContext -> Name -> [Id] -> Core.Expr -> Core.Expr
addLambdas fullTypeSchemes env context name args expr = case declarationTpScheme fullTypeSchemes env context name of
  -- No type found, just use `any`
  Nothing -> foldr Core.Lam expr $ map (`Core.Variable` Core.TAny) args
  Just ty@(Top.Quantification (tvars, qmap, t)) ->
    let
      (tvars', substitute) = case instantiationInTypeClassInstance context ty of
        Just (typeVar, instanceType) -> (filter (\v -> typeVarToId qmap v /= typeVar) tvars, Core.typeSubstitute typeVar instanceType)
        Nothing -> (tvars, id)
    in foldr (\x e -> Core.Forall (typeVarToId qmap x) Core.KStar e) (addLambdasForQType env qmap t substitute args expr) tvars'
    -- TODO: Use 'typeSubstitute'

addLambdasForQType :: ImportEnvironment -> QuantorMap -> Top.QType -> (Core.Type -> Core.Type) -> [Id] -> Core.Expr -> Core.Expr
addLambdasForQType env qmap (Top.Qualification ([], t)) substitute args expr = addLambdasForType env qmap t substitute args expr
addLambdasForQType env qmap (Top.Qualification (p : ps, t)) substitute (arg:args) expr =
    Core.Lam (Core.Variable arg $ substitute $ predicateToCoreType qmap p) $ addLambdasForQType env qmap (Top.Qualification (ps, t)) substitute args expr

addLambdasForType :: ImportEnvironment -> QuantorMap -> Top.Tp -> (Core.Type -> Core.Type) -> [Id] -> Core.Expr -> Core.Expr
addLambdasForType _ _ _ _ [] expr = expr
addLambdasForType env qmap (Top.TApp (Top.TApp (Top.TCon "->") argType) retType) substitute (arg:args) expr =
    Core.Lam (Core.Variable arg $ substitute $ typeToCoreType qmap argType)
        $ addLambdasForType env qmap retType substitute args expr
addLambdasForType env qmap tp substitute args expr =
    case tp' of
        -- Verify that the resulting type is a function type
        Top.TApp (Top.TApp (Top.TCon "->") _) _ -> addLambdasForType env qmap tp' substitute args expr
        _ -> internalError "ToCoreDecl" "Declaration" ("Expected a function type, got " ++ show tp' ++ " instead")
    where
        tp' = applyTypeSynonym env tp []

applyTypeSynonym :: ImportEnvironment -> Top.Tp -> Top.Tps -> Top.Tp
applyTypeSynonym env tp@(Top.TCon name) tps = case M.lookup (nameFromString name) $ typeSynonyms env of
    Just (arity, fn) ->
        let
            tps' = drop arity tps
            tp' = fn (take arity tps)
        in
            applyTypeSynonym env tp' tps'
    _ -> foldl (Top.TApp) tp tps
applyTypeSynonym env (Top.TApp t1 t2) tps = applyTypeSynonym env t1 (t2 : tps)
