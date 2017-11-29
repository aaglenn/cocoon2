{-
Copyrights (c) 2017. VMware, Inc. All right reserved. 

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}
{-# LANGUAGE ImplicitParams, RecordWildCards, TupleSections, LambdaCase #-}

module Datalog( refine2DL
              , factField
              , factSwitchId
              , factSwitchFailed
              , factSetSwitchFailed) where

import Control.Monad.State
import Data.List
import Data.Maybe
import Data.String.Utils

import Name
import Pos

import Util
import qualified SMT.SMTSolver   as SMT
import qualified Datalog.Datalog as DL
import Eval
import SMT
import Syntax
import Refine
import NS
import Relation
import Expr
import Type

refine2DL :: Refine -> ([SMT.Struct], [SMT.Function], [(Relation, ((DL.Relation, [DL.Rule]), [ [(DL.Relation, [DL.Rule])] ]))])
refine2DL r = 
    let ?r = r in
    let rels = refineRelsSorted r
        funcs = map (getFunc r) $ nub $ concatMap (relFuncsRec r) rels
        funcs' = map SMT.func2SMT funcs
        structs = map (\t -> SMT.struct2SMT (name t) $ typeCons $ fromJust $ tdefType t)
                  $ nub $ map (structTypeDef r . typ' r) 
                  $ filter (\case 
                             TStruct _ _ -> True
                             _           -> False) 
                  $ typeSort r $ nub $ concatMap (relTypes r) rels
        dlrels = zip rels $ map rel2DL rels
    in ((SMT.Struct "__lambda" [SMT.Constructor "__Lambda" [SMT.Var "__lambda_string" SMT.TString]]): structs, funcs', dlrels)

rel2DL :: (?r::Refine) => Relation -> ((DL.Relation, [DL.Rule]), [ [(DL.Relation, [DL.Rule])] ])
rel2DL rel = ((rel', rules), constrs)
    where rel' = DL.Relation (name rel) (map (\arg -> SMT.Var (name arg) (typ2SMT arg)) $ relArgs rel) (relIsView rel)
          rules = maybe []
                        (mapIdx (\rl@Rule{..} i -> let replacePH :: ECtx -> ENode -> State Int Expr
                                                       replacePH ctx (EPHolder _) | ctxInRuleL ctx || ctxInRelPred ctx = do
                                                           idx <- get
                                                           modify (+1)
                                                           return $ eVar $ "__ph" ++ show idx
                                                       replacePH _   e = return $ E e
                                                       (ruleLHS', ruleRHS') = evalState (do lhs <- mapIdxM (\l i' -> exprFoldCtxM replacePH (CtxRuleL rel rl i') l) ruleLHS
                                                                                            rhs <- mapM (exprFoldCtxM replacePH (CtxRuleR rel rl)) ruleRHS
                                                                                            return (lhs, rhs)) 0
                                                       rl' = Rule nopos ruleLHS' ruleRHS'
                                                       h = SMT.ERelPred (name rel) $ mapIdx (\e i' -> expr2SMT (CtxRuleL rel rl' i') e) ruleLHS'
                                                       hvars = concat $ mapIdx (\e i' -> exprVars (CtxRuleL rel rl' i') e) ruleLHS'
                                                       b = SMT.conj $ map (expr2SMT (CtxRuleR rel rl')) ruleRHS'
                                                       bvars = concatMap (exprVars (CtxRuleR rel rl')) ruleRHS'
                                                       vars = nub
                                                              $ map (\(vname, ctx) -> SMT.Var vname $ typ2SMT $ exprType ?r ctx $ eVar vname)
                                                              $ hvars ++ bvars
                                                   in DL.Rule vars h b $ fromIntegral i))
                        $ relDef rel
          constrs = mapIdx (constr2DL rel) $ relConstraints rel

-- pick the subset of relations used in roles
--      generate persistent realized versions of these relations (no constraints or rules)
--      generate delta relations with additional polarity field and
--      rules to compute it from base relations:
--          delta(true, x)  :- rel(x) /\ not rel'(x)
--          delta(false, x) :- not rel(x) /\ rel'(x)

constr2DL :: (?r::Refine) => Relation -> Constraint -> Int -> [(DL.Relation, [DL.Rule])]
constr2DL rel (PrimaryKey _ fs) i            = pkeyIndex rel fs ++ uniqueConstr i rel fs
constr2DL rel (Unique _ fs)     i            = uniqueConstr i rel fs
constr2DL rel (Check _ e)       i            = [fst $ rel2DL rel']
    where relname = name rel ++ "_check_" ++ show i
          as = relArgs rel
          rel' = Relation nopos False relname as []
                          $ Just [Rule nopos (map (eVar . name) as) 
                                       [eRelPred (name rel) (map (eVar . name) as), eNot e]]
constr2DL rel (ForeignKey _ fs rrel _) i     = [fst $ rel2DL rel']
    where -- R_foreign_i <- RRel(x,_), not RR_primary()
          relname = name rel ++ "_foreign_" ++ show i
          as = relArgs rel
          rel' = Relation nopos False relname as []
                          $ Just [Rule nopos (map (eVar . name) as) 
                                       [ eRelPred (name rel) (map (eVar . name) as)
                                       , eNot $ eRelPred (primaryIdxName rrel) fs ]]

primaryIdxName :: String -> String
primaryIdxName rel = rel ++ "_primary_"

pkeyIndex :: (?r::Refine) => Relation -> [Expr] -> [(DL.Relation, [DL.Rule])]
pkeyIndex rel fs = [fst $ rel2DL rel']
    where -- R_primary(x) <- R(x,y)
          relname = primaryIdxName $ name rel
          as = relArgs rel
          keys = mapIdx (\f i -> Field nopos ("col" ++ show i) $ exprType ?r (CtxRelKey rel) f) fs
          rel' = Relation nopos False relname keys []
                          $ Just [Rule nopos fs [eRelPred (name rel) (map (eVar . name) as)]]


uniqueConstr :: (?r::Refine) => Int -> Relation -> [Expr] -> [(DL.Relation, [DL.Rule])]
uniqueConstr i rel fs = [fst $ rel2DL rel']
    where -- R_unique_(x1,x2) <- R(x1), R(x2), x1!=x2, x1.f == x2.f
          as1 = map (\f -> f{fieldName = fieldName f ++ "1"}) $ relArgs rel
          as2 = map (\f -> f{fieldName = fieldName f ++ "2"}) $ relArgs rel
          relname = name rel ++ "_unique_" ++ show i ++ "_" ++ (replace "." "_" $ intercalate "_" $ map show fs)
          neq = disj $ map (\(f1, f2) -> eNot $ eBinOp Eq (eVar $ name f1) (eVar $ name f2)) $ zip as1 as2 
          rename suff = exprVarRename (++suff)
          eq  = conj $ map (\f -> eBinOp Eq (rename "1" f) (rename "2" f)) fs
          rel' = Relation nopos False relname [Field nopos "r1" $ tTuple $ map typ as1, Field nopos "r2" $ tTuple $ map typ as2] []
                          $ Just [Rule nopos [eTuple $ map (eVar . name) as1, eTuple $ map (eVar . name) as2]
                                             [ eRelPred (name rel) (map (eVar . name) as1)
                                             , eRelPred (name rel) (map (eVar . name) as2)
                                             , neq, eq]]

fieldCond :: (?r::Refine) => ECtx -> Expr -> Expr
fieldCond ctx e = conj $ execState (exprTraverseCtxM (fieldCond' ?r) ctx e) []

fieldCond' :: Refine -> ECtx -> ENode -> State [Expr] ()
fieldCond' _ _   (EVar _ _)      = return ()
fieldCond' r ctx (EField _ e f)  = do 
    let TStruct _ cs = typ' r $ exprType r ctx e
    let cs' = structFieldConstructors cs f
    if length cs == length cs'
       then return ()
       else modify ((eMatch e $ map (\c -> (eStruct (name c) (map (\_ -> ePHolder) $ consArgs c), eTrue)) cs' ++ [(ePHolder, eFalse)]):)
fieldCond' _ _   e               = error $ "SMT.fieldCond' " ++ show e


factField :: Refine -> DL.Fact -> (Expr -> Expr) -> Expr
factField r (DL.Fact rel as) g = evalConstExpr r $ g (eStruct rel $ map SMT.exprFromSMT as)

factSwitchId :: Refine -> String -> DL.Fact -> Integer
factSwitchId r rname f = let rel = getRelation r rname
                             Just [key] = relPrimaryKey rel
                             mkkey (E (EVar _ v))     e' = eField e' v
                             mkkey (E (EField _ x a)) e' = eField (mkkey x e') a
                             mkkey x                  _  = error $ "Controller.sync: mmkkey " ++ show x
                             E (EBit _ _ swid) = factField r f (mkkey key)
                         in swid

factSwitchFailed :: Refine -> DL.Fact -> Bool
factSwitchFailed r f = let E (EBool _ fl) = factField r f (\v -> eField v "failed") in fl

factSetSwitchFailed :: Refine -> String -> DL.Fact -> Bool -> DL.Fact
factSetSwitchFailed r rname (DL.Fact n as) fl = let rel = getRelation r rname
                                                    Just i = findIndex ((=="failed") . name) $ relArgs rel
                                                in DL.Fact n $ take i as ++ (SMT.EBool fl : drop (i+1) as)
