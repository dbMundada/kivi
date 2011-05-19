module LambdaLifter where


import Utils
import Common
import Data.Set (Set)
import qualified Data.Set as Set
import NameSupply
import Data.Map (Map)
import qualified Data.Map as Map
import List
import Debug.Trace


type AnnExpr a b = (b, AnnExpr' a b)

data AnnExpr' a b = AVar Name
                  | ANum Int
                  | AConstr Int Int
                  | AAp (AnnExpr a b) (AnnExpr a b)
                  | ALet IsRec [AnnDefn a b] (AnnExpr a b)
                  | ACase (AnnExpr a b) [AnnAlt a b]
                  | ALam [a] (AnnExpr a b)
    deriving Show

type AnnDefn a b = (a, AnnExpr a b)
type AnnAlt a b = (Int, [a], AnnExpr a b)
type AnnProgram a b = [(Name, [a], AnnExpr a b)]


lift :: CoreProgram -> CoreProgram
lift = collectScs . rename . abstract . freeVars


freeVars :: CoreProgram -> AnnProgram Name (Set Name)
freeVars [] = []
freeVars ((name, args, expr) : scs) = (name, args, calcFreeVars (Set.fromList args) expr) : (freeVars scs)


calcFreeVars :: (Set Name) -> CoreExpr -> AnnExpr Name (Set Name)
calcFreeVars localVars (ENum n) = (Set.empty, ANum n)
calcFreeVars localVars (EVar v) | Set.member v localVars = (Set.singleton v, AVar v)
                                | otherwise = (Set.empty, AVar v)
calcFreeVars localVars (EAp e1 e2) = (Set.union s1 s2, AAp ae1 ae2)
    where
        ae1@(s1, _) = calcFreeVars localVars e1
        ae2@(s2, _) = calcFreeVars localVars e2
calcFreeVars localVars (ELam args expr) = (Set.difference fvs argsSet, ALam args expr')
    where
        expr'@(fvs, _) = calcFreeVars (Set.union localVars argsSet) expr
        argsSet = Set.fromList args
calcFreeVars localVars (ELet isRec defns expr) =
    (Set.union bodyFvs defnsFvs, ALet isRec defns' expr')
    where
        binders = Set.fromList $ bindersOf defns
        exprLvs = Set.union binders localVars
        rhsLvs | isRec = exprLvs
               | otherwise = localVars
        -- annotated stuff
        rhss' = map (calcFreeVars rhsLvs) $ rhssOf defns
        defns' = zip (Set.toList binders) rhss'
        expr' = calcFreeVars exprLvs expr
        rhssFvs = foldl Set.union Set.empty (map freeVarsOf rhss')
        defnsFvs | isRec = Set.difference rhssFvs binders
                 | otherwise = rhssFvs
        bodyFvs = Set.difference (freeVarsOf expr') binders
calcFreeVars localVars (ECase expr alts) =
    (fvs, ACase expr' alts')
    where
        expr'@(exprFvs, _) = calcFreeVars localVars expr
        (fvs, alts') = mapAccumL freeVarsAlts exprFvs alts

        freeVarsAlts fvs (t, vars, body) =
            (Set.union fvs (Set.difference bodyFvs varsSet), (t, vars, body'))
            where
                body'@(bodyFvs, _) = calcFreeVars (Set.union varsSet localVars) body
                varsSet = Set.fromList vars
calcFreeVars localVars (EConstr t n) =
    (Set.empty, AConstr t n)


abstract :: AnnProgram Name (Set Name) -> CoreProgram
abstract program = [(name, args, abstractExpr expr) | (name, args, expr) <- program]


abstractExpr :: AnnExpr Name (Set Name) -> CoreExpr
abstractExpr (freeVars, ANum n) = ENum n
abstractExpr (freeVars, AVar v) = EVar v
abstractExpr (freeVars, AAp e1 e2) = EAp (abstractExpr e1) (abstractExpr e2)
abstractExpr (freeVars, ALet isRec defns expr) =
    ELet isRec [(name, abstractExpr body) | (name, body) <- defns] (abstractExpr expr)
abstractExpr (freeVars, ALam args expr) =
    foldl EAp sc $ map EVar freeVarsList
    where
        freeVarsList = Set.toList freeVars
        sc = ELet False [("sc", scBody)] (EVar "sc")
        scBody = ELam (freeVarsList ++ args) (abstractExpr expr)
abstractExpr (freeVars, ACase expr alts) =
    ECase (abstractExpr expr) alts'
    where
        alts' = map abstractAlt alts
        abstractAlt (t, vars, expr) = (t, vars, abstractExpr expr)
abstractExpr (freeVars, AConstr t a) = EConstr t a


rename :: CoreProgram -> CoreProgram
rename scs = snd $ mapAccumL renameSc initialNameSupply scs


renameSc :: NameSupply -> CoreScDefn -> (NameSupply, CoreScDefn)
renameSc ns (name, args, expr) =
    (ns2, (name, args', expr'))
    where
        (ns1, args', mapping) = newNames ns args
        (ns2, expr') = renameExpr mapping ns1 expr


newNames :: NameSupply -> [Name] -> (NameSupply, [Name], Map Name Name)
newNames ns names =
    (ns', names', mapping)
    where
        (ns', names') = getNames ns names
        mapping = Map.fromList $ zip names names'


renameExpr :: Map Name Name -> NameSupply -> CoreExpr -> (NameSupply, CoreExpr)
renameExpr mapping ns (ENum n) = (ns, ENum n)
renameExpr mapping ns (EVar v) =
    (ns, EVar v') -- for built-int functions (+,-, etc.) we have to use old name
    where
        v' = case Map.lookup v mapping of
            (Just x) -> x
            Nothing -> v
renameExpr mapping ns (EAp e1 e2) =
    (ns2, EAp e1' e2')
    where
        (ns1, e1') = renameExpr mapping ns e1
        (ns2, e2') = renameExpr mapping ns1 e2
renameExpr mapping ns (ELam args expr) =
    (ns2, ELam args' expr')
    where
        (ns1, args', mapping') = newNames ns args
        (ns2, expr') = renameExpr (Map.union mapping' mapping) ns1 expr
renameExpr mapping ns (ELet isRec defns expr) =
    (ns2, ELet isRec defns' expr')
    where
        binders = bindersOf defns
        rhss = rhssOf defns
        (ns1, binders', mapping') = newNames ns binders
        exprMapping = (Map.union mapping' mapping)
        defnsMapping | isRec = exprMapping
                     | otherwise = mapping
        (ns2, rhss') = mapAccumL (renameExpr exprMapping) ns1 rhss
        (ns3, expr') = renameExpr exprMapping ns2 expr
        defns' = zip binders' rhss'
renameExpr mapping ns (ECase expr alts) =
    (ns2, ECase expr' alts')
    where
        (ns1, expr') = renameExpr mapping ns expr
        (ns2, alts') = mapAccumL (renameAlt mapping) ns1 alts

        renameAlt mapping ns (t, vars, body) =
            (ns2, (t, vars', body'))
            where
                (ns1, vars', mapping') = newNames ns vars
                (ns2, body') = renameExpr (Map.union mapping' mapping) ns1 body
renameExpr mapping ns (EConstr t a) = (ns, EConstr t a)


collectScs :: CoreProgram -> CoreProgram
collectScs scs = foldl collectSc [] scs


collectSc :: [CoreScDefn] -> CoreScDefn -> [CoreScDefn]
collectSc scsAcc (name, args, expr) = [(name, args, expr')] ++ scsAcc ++ scs
    where
        (scs, expr') = collectExpr expr


collectExpr :: CoreExpr -> ([CoreScDefn], CoreExpr)
collectExpr (ENum n) = ([], ENum n)
collectExpr (EVar v) = ([], EVar v)
collectExpr (EAp e1 e2) =
    (scs1 ++ scs2, EAp e1' e2')
    where
        (scs1, e1') = collectExpr e1
        (scs2, e2') = collectExpr e2
collectExpr (ELam args expr) = (scs, ELam args expr')
    where (scs, expr') = collectExpr expr
collectExpr (ELet isRec defns expr) =
    (defnsScs ++ localScs ++ exprScs, mkELet isRec vars expr')
    where
        (defnsScs, defns') = mapAccumL collectDef [] defns
        localScs = map createSc scDefns
        (scDefns, vars) = partition isSc defns'
        (exprScs, expr') = collectExpr expr

        -- is supercombinator predicate
        isSc (name, (ELam _ _)) = True
        isSc (name, _) = False

        -- helper function to create supercombinator
        createSc (name, ELam args expr) = (name, args, expr)

        -- helper to extract supercombinators nested in definitions
        collectDef scsAcc (name, expr) =
            (scsAcc ++ scs, (name, expr'))
            where (scs, expr') = collectExpr expr

        --getting rid of let expressions with empty definitions part
        mkELet isRec vars expr =
            case length vars > 0 of
                True -> ELet isRec vars expr
                False -> expr
collectExpr (ECase expr alts) =
    (exprScs ++ altsScs, ECase expr' alts')
    where
        (exprScs, expr') = collectExpr expr
        (altsScs, alts') = mapAccumL collectAlt [] alts

        collectAlt scs (t, vars, expr) =
            (scs ++ exprScs, (t, vars, expr'))
            where (exprScs, expr') = collectExpr expr
collectExpr (EConstr t a) = ([], EConstr t a)


freeVarsOf :: AnnExpr Name (Set Name) -> Set Name
freeVarsOf (fvs, _) = fvs
