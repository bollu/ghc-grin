{-# LANGUAGE LambdaCase, TupleSections, OverloadedStrings #-}
module Lambda.DeadFunctionElimination where

-- NOTE: only after lambda lifting and whole program availablity

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Functor.Foldable as Foldable
import qualified Data.Foldable

import Lambda.Syntax

deadFunctionElimination :: Program -> Program
deadFunctionElimination (Program exts sdata defs) = Program liveExts liveSData liveDefs where

  liveSData = [sd  | sd <- sdata, Set.member (sName sd) liveNames]
  liveExts  = [ext | ext <- exts, Set.member (eName ext) liveNames]
  liveDefs  = [def | def@(Def name _ _) <- defs, Set.member name liveSet]

  liveNames = cata collectAll $ Program [] [] liveDefs -- collect all live names

  defMap :: Map Name Def
  defMap = Map.fromList [(name, def) | def@(Def name _ _) <- defs]

  lookupDef :: Name -> Maybe Def
  lookupDef name = Map.lookup name defMap

  liveSet :: Set Name
  liveSet = fst $ until (\(live, visited) -> live == visited) visit (Set.singleton ":Main.main", mempty)

  visit :: (Set Name, Set Name) -> (Set Name, Set Name)
  visit (live, visited) = (mappend live seen, mappend visited toVisit) where
    toVisit = Set.difference live visited
    seen    = foldMap (maybe mempty (cata collect) . lookupDef) toVisit

  collect :: ExpF (Set Name) -> Set Name
  collect = \case
    AppF name args  | Map.member name defMap  -> mconcat $ Set.singleton name : args
    VarF _ name     | Map.member name defMap  -> Set.singleton name
    exp -> Data.Foldable.fold exp

  collectAll :: ExpF (Set Name) -> Set Name
  collectAll = \case
    AppF name args  -> mconcat $ Set.singleton name : args
    VarF _ name     -> Set.singleton name
    exp -> Data.Foldable.fold exp
