{-
Copyrights (c) 2016. Samsung Electronics Ltd. All right reserved. 

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
{-# LANGUAGE RecordWildCards, LambdaCase #-}

module Refine( funcGraph
             , funcGraphNoSink
             , refineStructs
             --, refineIsMulticast
             --, refineIsDeterministic
             , refineRelsSorted
             , refineRelsUsedInPorts
             , refineAddDelta) where

import Data.List
import Data.Maybe
import qualified Data.Graph.Inductive as G

import Relation
import Port
import Expr
import Syntax
import Name
import NS


funcGraph :: Refine -> G.Gr String ()
funcGraph Refine{..} = 
    let g0 = foldl' (\g (i,f) -> G.insNode (i,name f) g)
                    G.empty $ zip [0..] refineFuncs in
    foldl' (\g (i,f) -> case funcDef f of
                             Nothing -> g
                             Just e  -> foldl' (\g' f' -> G.insEdge (i, fromJust $ findIndex ((f'==) . name) $ refineFuncs, ()) g') g (exprFuncs e))
           g0 $ zip [0..] refineFuncs

funcGraphNoSink :: Refine -> G.Gr String ()
funcGraphNoSink r@Refine{..} = 
    let g0 = foldl' (\g (i,f) -> G.insNode (i,name f) g)
                    G.empty $ zip [0..] refineFuncs in
    foldl' (\g (i,f) -> case funcDef f of
                             Nothing -> g
                             Just e  -> foldl' (\g' f' -> if funcType (getFunc r f') == tSink 
                                                             then G.insEdge (i, fromJust $ findIndex ((f'==) . name) $ refineFuncs, ()) g'
                                                             else g') g (exprFuncs e))
           g0 $ zip [0..] refineFuncs



refineStructs :: Refine -> [Type]
refineStructs r = concatMap (\t -> case t of 
                                        TypeDef _ _ (Just t'@(TStruct _ _)) -> [t']
                                        _                                   -> []) $ refineTypes r

{-
refineIsMulticast :: Maybe Refine -> Refine -> String -> Bool
refineIsMulticast mra rc rlname = any (exprIsMulticast rc . roleBody . getRole rc) roles
    where new = maybe [] (\ra -> (map name (refineRoles rc) \\ map name (refineRoles ra))) mra
          roles = rlname : intersect new (roleSendsToRolesRec rc new rlname)
-}

{-    
refineIsDeterministic :: Maybe Refine -> Refine -> String -> Bool
refineIsDeterministic mra rc rlname = any (exprIsDeterministic rc . roleBody . getRole rc) roles
    where new = maybe [] (\ra -> (map name (refineRoles rc) \\ map name (refineRoles ra))) mra
          roles = rlname : intersect new (roleSendsToRolesRec rc new rlname)
-}

refineRelsSorted :: Refine -> [Relation]
refineRelsSorted r = map (getRelation r) $ reverse $ G.topsort' $ relGraph r

-- relations referenced in roles
refineRelsUsedInPorts :: Refine -> [String]
refineRelsUsedInPorts r = nub $ concatMap (portUsesRels r) $ refinePorts r

-- for every relation referenced in a role (whether a table or a view), add
-- 1. Realized-state _table_ with the same columns as the primary relation, but
--    without any rules or constraints 
-- 2. Delta view with extra polarity column that keeps track of the
--    difference between desired and realized state
refineAddDelta :: Refine -> Refine
refineAddDelta r = foldl' (\r' rname -> let (realized, delta) = relMkDelta $ getRelation r' rname
                                        in r'{refineRels = refineRels r' ++ [realized,delta]}) 
                   r $ nub $ refineRelsUsedInPorts r ++ (map switchRel $ refineSwitches r)
