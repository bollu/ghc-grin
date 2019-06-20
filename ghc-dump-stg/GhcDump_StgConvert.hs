{-# LANGUAGE RecordWildCards, LambdaCase, TupleSections #-}
module GhcDump_StgConvert where

import GhcPrelude

import qualified Data.ByteString.Char8 as BS8

import qualified CoreSyn      as GHC
import qualified DataCon      as GHC
import qualified DynFlags     as GHC
import qualified FastString   as GHC
import qualified ForeignCall  as GHC
import qualified Id           as GHC
import qualified IdInfo       as GHC
import qualified Literal      as GHC
import qualified Module       as GHC
import qualified Name         as GHC
import qualified Outputable   as GHC
import qualified PrimOp       as GHC
import qualified RepType      as GHC
import qualified StgSyn       as GHC
import qualified TyCon        as GHC
import qualified Type         as GHC
import qualified Unique       as GHC
import qualified Var          as GHC

import Control.Monad
import Control.Monad.Trans.State.Strict
import qualified Data.List.NonEmpty as NonEmpty
import Data.List (foldl')
import Data.IntMap (IntMap)
import Data.Maybe (maybe)
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map
import qualified Data.Set as Set

import GhcDump_StgAst

fastStringToText :: GHC.FastString -> T_Text
fastStringToText = GHC.fastStringToByteString

occNameToText :: GHC.OccName -> T_Text
occNameToText = GHC.fastStringToByteString . GHC.occNameFS

mkTyConId :: GHC.TyCon -> TyConId
mkTyConId = TyConId . cvtUnique . GHC.getUnique

getTyCon :: GHC.Type -> Maybe GHC.TyCon
getTyCon t = fst <$> GHC.splitTyConApp_maybe t

cvtTyCon :: GHC.TyCon -> M TyConId
cvtTyCon x = do
  let key = uniqueKey x
  new <- IntMap.notMember key <$> gets envTyCons
  when new $ modify' $ \m@Env{..} -> m {envTyCons = IntMap.insert key x envTyCons}
  pure $ mkTyConId x

-- NOTE: does not collect TyCon
typeToRep :: GHC.Type -> TypeInfo
typeToRep t = TypeInfo
  { tType  = cvtSDoc . GHC.ppr $ t
  , tTyCon = mkTyConId <$> getTyCon t
  , tRep   = if GHC.resultIsLevPoly t
              then Nothing
              else Just . map cvtPrimRep . GHC.typePrimRepArgs $ t
  }

-- NOTE: collects TyCon
typeToRepM :: GHC.Type -> M TypeInfo
typeToRepM t = do
  tyConId <- sequence (cvtTyCon <$> getTyCon t)
  pure TypeInfo
    { tType  = cvtSDoc . GHC.ppr $ t
    , tTyCon = tyConId
    , tRep   = if GHC.resultIsLevPoly t
                then Nothing
                else Just . map cvtPrimRep . GHC.typePrimRepArgs $ t
    }

cvtSDoc :: GHC.SDoc -> T_Text
cvtSDoc = BS8.pack . GHC.showSDoc GHC.unsafeGlobalDynFlags

cvtModuleName :: GHC.ModuleName -> ModuleName
cvtModuleName = ModuleName . fastStringToText . GHC.moduleNameFS

cvtPrimElemRep :: GHC.PrimElemRep -> PrimElemRep
cvtPrimElemRep = \case
  GHC.Int8ElemRep   -> Int8ElemRep
  GHC.Int16ElemRep  -> Int16ElemRep
  GHC.Int32ElemRep  -> Int32ElemRep
  GHC.Int64ElemRep  -> Int64ElemRep
  GHC.Word8ElemRep  -> Word8ElemRep
  GHC.Word16ElemRep -> Word16ElemRep
  GHC.Word32ElemRep -> Word32ElemRep
  GHC.Word64ElemRep -> Word64ElemRep
  GHC.FloatElemRep  -> FloatElemRep
  GHC.DoubleElemRep -> DoubleElemRep

cvtPrimRep :: GHC.PrimRep -> PrimRep
cvtPrimRep = \case
  GHC.VoidRep     -> VoidRep
  GHC.LiftedRep   -> LiftedRep
  GHC.UnliftedRep -> UnliftedRep
  GHC.IntRep      -> IntRep
  GHC.WordRep     -> WordRep
  GHC.Int64Rep    -> Int64Rep
  GHC.Word64Rep   -> Word64Rep
  GHC.AddrRep     -> AddrRep
  GHC.FloatRep    -> FloatRep
  GHC.DoubleRep   -> DoubleRep
  GHC.VecRep i e  -> VecRep i $ cvtPrimElemRep e

cvtLitNumType :: GHC.LitNumType -> LitNumType
cvtLitNumType = \case
  GHC.LitNumInteger -> LitNumInteger
  GHC.LitNumNatural -> LitNumNatural
  GHC.LitNumInt     -> LitNumInt
  GHC.LitNumInt64   -> LitNumInt64
  GHC.LitNumWord    -> LitNumWord
  GHC.LitNumWord64  -> LitNumWord64

cvtLit :: GHC.Literal -> Lit
cvtLit = \case
  GHC.MachChar x      -> MachChar x
  GHC.MachStr x       -> MachStr x
  GHC.MachNullAddr    -> MachNullAddr
  GHC.MachFloat x     -> MachFloat x
  GHC.MachDouble x    -> MachDouble x
  GHC.MachLabel x _ _ -> MachLabel $ fastStringToText  x
  GHC.LitNumber t i _ -> LitNumber (cvtLitNumType t) i

cvtUnique :: GHC.Unique -> Unique
cvtUnique u = Unique a b
  where (a,b) = GHC.unpkUnique u

data Env
  = Env
  { envExternals  :: IntMap GHC.Id
  , envDataCons   :: IntMap GHC.DataCon
  , envTyCons     :: IntMap GHC.TyCon
  }

emptyEnv :: Env
emptyEnv = Env
  { envExternals  = IntMap.empty
  , envDataCons   = IntMap.empty
  , envTyCons     = IntMap.empty
  }

type M = State Env

uniqueKey :: GHC.Uniquable a => a -> Int
uniqueKey = GHC.getKey . GHC.getUnique

mkBinderId :: GHC.Uniquable a => a -> BinderId
mkBinderId = BinderId . cvtUnique . GHC.getUnique

cvtVar :: GHC.Id -> M BinderId
cvtVar x = do
  let name = GHC.getName x
  when (GHC.isExternalName name) $ do
    let key = uniqueKey x
    new <- IntMap.notMember key <$> gets envExternals
    when new $ modify' $ \m@Env{..} -> m {envExternals = IntMap.insert key x envExternals}
  pure $ mkBinderId x

cvtBinder :: GHC.Id -> SBinder
cvtBinder v
  | GHC.isId v = SBinder
      { sbinderName = occNameToText $ GHC.getOccName v
      , sbinderId   = BinderId . cvtUnique . GHC.idUnique $ v
      , sbinderType = typeToRep $ GHC.idType v
      }
  | otherwise = error $ "Type binder in STG: " ++ (show $ occNameToText $ GHC.getOccName v)

cvtDataCon :: GHC.DataCon -> M BinderId
cvtDataCon x = do
  let key = uniqueKey x
  new <- IntMap.notMember key <$> gets envDataCons
  when new $ modify' $ \m@Env{..} -> m {envDataCons = IntMap.insert key x envDataCons}
  pure . BinderId . cvtUnique . GHC.getUnique $ x

cvtCCallTarget :: GHC.CCallTarget -> CCallTarget
cvtCCallTarget = \case
  GHC.StaticTarget _ t _ _  -> StaticTarget $ fastStringToText t
  GHC.DynamicTarget         -> DynamicTarget

cvtCCallConv :: GHC.CCallConv -> CCallConv
cvtCCallConv = \case
  GHC.CCallConv           -> CCallConv
  GHC.CApiConv            -> CApiConv
  GHC.StdCallConv         -> StdCallConv
  GHC.PrimCallConv        -> PrimCallConv
  GHC.JavaScriptCallConv  -> JavaScriptCallConv

cvtSafety :: GHC.Safety -> Safety
cvtSafety = \case
  GHC.PlaySafe          -> PlaySafe
  GHC.PlayInterruptible -> PlayInterruptible
  GHC.PlayRisky         -> PlayRisky

cvtForeignCall :: GHC.ForeignCall -> ForeignCall
cvtForeignCall (GHC.CCall (GHC.CCallSpec t c s)) = ForeignCall (cvtCCallTarget t) (cvtCCallConv c) (cvtSafety s)

cvtOp :: GHC.StgOp -> StgOp
cvtOp = \case
  GHC.StgPrimOp o     -> StgPrimOp (occNameToText $ GHC.primOpOcc o)
  GHC.StgPrimCallOp c -> StgPrimCallOp PrimCall -- TODO
  GHC.StgFCallOp f _  -> StgFCallOp $ cvtForeignCall f

cvtArg :: GHC.StgArg -> M SArg
cvtArg = \case
  GHC.StgVarArg o -> StgVarArg <$> cvtVar o
  GHC.StgLitArg l -> pure $ StgLitArg (cvtLit l)

cvtUpdateFlag :: GHC.UpdateFlag -> UpdateFlag
cvtUpdateFlag = \case
  GHC.ReEntrant   -> ReEntrant
  GHC.Updatable   -> Updatable
  GHC.SingleEntry -> SingleEntry

cvtAlt :: GHC.StgAlt -> M SAlt
cvtAlt (con, bs, e) = Alt <$> cvtAltCon con <*> pure (map cvtBinder bs) <*> cvtExpr e

cvtAltCon :: GHC.AltCon -> M SAltCon
cvtAltCon = \case
  GHC.DataAlt con -> AltDataCon <$> cvtDataCon con
  GHC.LitAlt l    -> pure . AltLit $ cvtLit l
  GHC.DEFAULT     -> pure $ AltDefault

cvtExpr :: GHC.StgExpr -> M SExpr
cvtExpr = \case
  GHC.StgApp f ps         -> StgApp <$> cvtVar f <*> mapM cvtArg ps
  GHC.StgLit l            -> pure $ StgLit (cvtLit l)
  GHC.StgConApp dc ps ts  -> StgConApp <$> cvtDataCon dc <*> mapM cvtArg ps <*> mapM typeToRepM ts
  GHC.StgOpApp o ps t     -> StgOpApp (cvtOp o) <$> mapM cvtArg ps <*> typeToRepM t
  GHC.StgLam bs e         -> StgLam (map cvtBinder $ NonEmpty.toList bs) <$> cvtExpr e
  GHC.StgCase e b _ al    -> StgCase <$> cvtExpr e <*> pure (cvtBinder b) <*> mapM cvtAlt al
  GHC.StgLet b e          -> StgLet <$> cvtBind b <*> cvtExpr e
  GHC.StgLetNoEscape b e  -> StgLetNoEscape <$> cvtBind b <*> cvtExpr e
  GHC.StgTick _ e         -> cvtExpr e

cvtRhs :: GHC.StgRhs -> M SRhs
cvtRhs = \case
  GHC.StgRhsClosure _ b fs u bs e -> StgRhsClosure <$> mapM cvtVar fs <*> pure (cvtUpdateFlag u) <*> pure (map cvtBinder bs) <*> cvtExpr e
  GHC.StgRhsCon _ dc args         -> StgRhsCon <$> cvtDataCon dc <*> mapM cvtArg args

cvtBind :: GHC.StgBinding -> M SBinding
cvtBind = \case
  GHC.StgNonRec b r -> StgNonRec (cvtBinder b) <$> cvtRhs r
  GHC.StgRec    bs  -> StgRec <$> sequence [(cvtBinder b,) <$> cvtRhs r | (b, r) <- bs]

cvtTopBind :: GHC.StgTopBinding -> M STopBinding
cvtTopBind = \case
  GHC.StgTopLifted b        -> StgTopLifted <$> cvtBind b
  GHC.StgTopStringLit b bs  -> pure $ StgTopStringLit (cvtBinder b) bs

cvtTopBinds :: [GHC.StgTopBinding] -> M [STopBinding]
cvtTopBinds binds = do
  bs <- mapM cvtTopBind binds
  addTyConDataCons
  pure bs

addTyConDataCons :: M ()
addTyConDataCons = do
  tcs <- IntMap.elems . envTyCons <$> get
  forM_ tcs $ \tc -> do
    mapM_ cvtDataCon (GHC.tyConDataCons tc)

cvtModule :: String -> GHC.ModuleName -> [GHC.StgTopBinding] -> SModule
cvtModule phase modName' binds =
  Module
  { modulePhase       = BS8.pack phase
  , moduleName        = modName
  , moduleDependency  = Set.toList . Set.delete modName . Set.fromList . map fst $ externals
  , moduleExternals   = externals
  , moduleDataCons    = dataCons
  , moduleTyCons      = tyCons
  , moduleExported    = exported
  , moduleTopBindings = topBinds
  } where
      (topBinds, Env{..}) = runState (cvtTopBinds binds) emptyEnv
      stgTopIds           = concatMap topBindIds binds
      topKeys             = IntSet.fromList $ map uniqueKey stgTopIds
      exported            = groupByModule [ (maybe modName (cvtModuleName . GHC.moduleName) $ GHC.nameModule_maybe $ GHC.getName id, mkBinderId id)
                                          | id <- stgTopIds, GHC.isExportedId id]
      modName             = cvtModuleName modName'
      externals           = groupByModule [mkExternalName e | (k,e) <- IntMap.toList envExternals, IntSet.notMember k topKeys]
      dataCons            = groupByModule . map mkDataCon $ IntMap.elems envDataCons
      tyCons              = groupByModule . map mkTyCon $ IntMap.elems envTyCons

-- utils

groupByModule :: [(ModuleName, b)] -> [(ModuleName, [b])]
groupByModule = Map.toList . foldl' (\a (m,b) -> Map.insertWith (++) m [b] a) Map.empty

mkExternalName :: GHC.Id -> (ModuleName, SBinder)
mkExternalName x = (cvtModuleName $ GHC.moduleName $ GHC.nameModule $ GHC.getName x, cvtBinder x)

mkDataCon :: GHC.DataCon -> (ModuleName, SBinder)
mkDataCon dc = (cvtModuleName $ GHC.moduleName $ GHC.nameModule x, b) where
  x = GHC.getName dc
  b = SBinder
      { sbinderName = occNameToText $ GHC.getOccName x
      , sbinderId   = BinderId . cvtUnique . GHC.getUnique $ x
      , sbinderType = typeToRep $ GHC.dataConRepType dc
      }

mkTyCon :: GHC.TyCon -> (ModuleName, STyCon)
mkTyCon tc = (cvtModuleName $ GHC.moduleName $ GHC.nameModule x, b) where
  x = GHC.getName tc
  b = TyCon
      { tcName      = occNameToText $ GHC.getOccName x
      , tcId        = mkTyConId tc
      , tcDataCons  = map mkBinderId $ GHC.tyConDataCons tc
      }

topBindIds :: GHC.StgTopBinding -> [GHC.Id]
topBindIds = \case
  GHC.StgTopLifted (GHC.StgNonRec b _)  -> [b]
  GHC.StgTopLifted (GHC.StgRec bs)      ->  map fst bs
  GHC.StgTopStringLit b _               -> [b]
