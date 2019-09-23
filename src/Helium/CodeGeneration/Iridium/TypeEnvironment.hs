module Helium.CodeGeneration.Iridium.TypeEnvironment where

import Lvm.Common.Id(Id, idFromString)
import Lvm.Common.IdMap
import qualified Lvm.Core.Expr as Core
import Lvm.Core.Type
import qualified Helium.CodeGeneration.Core.TypeEnvironment as Core
import Helium.CodeGeneration.Iridium.Data
import Helium.CodeGeneration.Iridium.Type
import Helium.CodeGeneration.Iridium.Show
import Data.Maybe(catMaybes)
import Data.Either(isRight)

data TypeEnv = TypeEnv
  { teModuleName :: !Id
  , teDataTypes :: !(IdMap [DataTypeConstructor]) -- TODO: Make data types fully qualified
  , teValues :: !(IdMap ValueDeclaration)
  , teMethod :: !(Maybe (Id, Type))
  , teCoreEnv :: !Core.TypeEnvironment
  }

teReturnType :: TypeEnv -> Type
teReturnType (TypeEnv _ _ _ (Just (_, retType)) _) = retType

valueDeclaration :: TypeEnv -> Id -> ValueDeclaration
valueDeclaration env name = findMap name (teValues env)

builtins :: [(Id, ValueDeclaration)]
builtins = -- TODO: This should be replaced by parsing abstract definitions
  [ {- fn "$primUnsafePerformIO" [TypeAny] TypeAnyWHNF
  , fn "$primPutStrLn" [TypeAny] TypeAnyWHNF
  , fn "$primPatternFailPacked" [TypeDataType $ idFromString "[]"] TypeAnyWHNF
  , fn "$primConcat" [TypeAny] TypeAnyWHNF
  , fn "$primPackedToString" [TypeDataType $ idFromString "[]"] TypeAnyWHNF
  , fn "showString" [TypeAny] TypeAnyWHNF
  -} ]
  -- where
    -- fn :: String -> [PrimitiveType] -> PrimitiveType -> (Id, ValueDeclaration)
    -- fn name args result = (idFromString name, ValueFunction $ FunctionType args result)

data ValueDeclaration
  = ValueConstructor !DataTypeConstructor
  | ValueFunction !Id !Int !Type !CallingConvention
  | ValueVariable !Type
  deriving (Eq, Ord, Show)

typeOf :: TypeEnv -> Id -> Type
typeOf env name = case valueDeclaration env name of
  ValueFunction _ _ fntype _ -> fntype
  ValueVariable t -> t

enterFunction :: Id -> Type -> TypeEnv -> TypeEnv
enterFunction name fntype (TypeEnv moduleName datas values _ coreEnv) = TypeEnv moduleName datas values (Just (name, fntype)) coreEnv

expandEnvWith :: Local -> TypeEnv -> TypeEnv
expandEnvWith (Local name t) (TypeEnv moduleName datas values method coreEnv) = TypeEnv moduleName datas (insertMap name (ValueVariable t) values) method coreEnv'
  where
    coreEnv' = Core.typeEnvAddVariable (Core.Variable name t) coreEnv

expandEnvWithLocals :: [Local] -> TypeEnv -> TypeEnv
expandEnvWithLocals args env = foldr (\(Local arg t) -> expandEnvWith $ Local arg t) env args

expandEnvWithLet :: Id -> Expr -> TypeEnv -> TypeEnv
expandEnvWithLet name expr env = expandEnvWith (Local name (typeOfExpr (teCoreEnv env) expr)) env

expandEnvWithLetAlloc :: [Bind] -> TypeEnv -> TypeEnv
expandEnvWithLetAlloc thunks env = foldr (\b -> expandEnvWith $ bindLocal (teCoreEnv env) b) env thunks

expandEnvWithMatch :: [Maybe Local] -> TypeEnv -> TypeEnv
expandEnvWithMatch locals = expandEnvWithLocals $ catMaybes locals

resolveFunction :: TypeEnv -> Id -> Maybe (Id, Int, Type)
resolveFunction env name = case lookupMap name (teValues env) of
  Just (ValueFunction qualifiedName arity fn _) -> Just (qualifiedName, arity, fn)
  _ -> Nothing

valueOfMethod :: Id -> Declaration Method -> (Id, ValueDeclaration)
valueOfMethod name (Declaration qualifiedName _ _ _ (Method tp args _ annotations _ _)) = (name, ValueFunction qualifiedName (length $ filter isRight args) tp $ callingConvention annotations)

valueOfAbstract :: Id -> Declaration AbstractMethod -> (Id, ValueDeclaration)
valueOfAbstract name (Declaration qualifiedName _ _ _ (AbstractMethod arity fntype annotations)) = (name, ValueFunction qualifiedName arity fntype $ callingConvention annotations)