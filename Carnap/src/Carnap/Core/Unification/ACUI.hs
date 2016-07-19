{-#LANGUAGE GADTs, TypeOperators, ScopedTypeVariables, ExplicitForAll, ImpredicativeTypes, MultiParamTypeClasses, FlexibleContexts, PatternSynonyms #-}

module Carnap.Core.Unification.ACUI (
  ACUI(..), acuiUnifySys
  --acuiUnify, ACUI(..)
) where

  --to solve ACUI unification with constants we need to be able to find
  --all minimal solutions to a SAT problem
import Carnap.Core.Data.AbstractSyntaxClasses
import Carnap.Core.ModelChecking.SAT
import Carnap.Core.Unification.Unification
import Carnap.Core.Util
import Data.Typeable
import Control.Lens
import Control.Monad.State
import Control.Lens.Plated
import Data.List
import Data.Function
import Data.Proxy

class FirstOrder f => ACUI f where
  --only if this returns true are ther other functions valid
  isACUI :: f a -> Bool
  isId :: f a -> Bool --this one can be called weather acui or not
  getId :: Proxy a -> f a --given a valid term give the
  acuiOp :: f a -> f a -> f a
  unfoldTerm :: f a -> [f a]
  refoldTerms :: [f a] -> f a

isConst a = not (isVar a || isId a)

--a simiplair equation type we can work with here
data SimpleEquation a = a :==: a
    deriving(Eq, Ord, Show)

--export for testing
pattern (:===:) x y = x :==: y

--some helpers for minipulating equations
eqmap f (a :==: b) = f a :==: f b
eqfilter p (a :==: b) = (filter p a) :==: (filter p b)
eqadd (a :==: b) (a' :==: b') = (a ++ a') :==: (b ++ b')

--extracts the homogenous equation from the equation
homogenous eq = eqfilter isVar eq
--finds all inhomogenous equations that need to be solved
inhomogenous (l :==: r) = zip consts eqs
    where consts = filter isConst (nubBy (=*) $ l ++ r)
          eqs = map (\c -> eqfilter (\x -> isVar x || x =* c) (l :==: r)) consts

--returns true if term maps to 'true' in the SAT problem
isTrue a = isConst a && not (isId a)
--returns true if a term maps to 'false' in a the SAT problem
isFalse a = isId a


--converts a SimpleEquation [f a] into a sat problem
--toSatProblem :: (ACUI f a) => SimpleEquation [f a] -> ListSat (f a)
toSatProblem eq@(a :==: b) | ltrue && rtrue = makeProb []
                           | ltrue     = makeProb [map (LPos . AnyPig) b]
                           | rtrue     = makeProb [map (LPos . AnyPig) a]
                           | lfalse && rfalse = makeProb []
                           | lfalse    = makeProb $ map (\x -> [LNeg $ AnyPig x]) b
                           | rfalse    = makeProb $ map (\x -> [LNeg $ AnyPig x]) a
                           | otherwise = makeProb $ (impl a b) ++ (impl b a)
    where impl ant con = map (\lit -> (LNeg $ AnyPig lit):(map (LPos . AnyPig) con)) ant
          ltrue = any isTrue a
          rtrue = any isTrue b
          lfalse = all isFalse a
          rfalse = all isFalse b
          vars = nub $ map AnyPig (filter isVar (a ++ b))
          makeProb = makeProblemWith vars

--returns true if the left side is strictly greater than the right side
--dominates :: [Literal (AnyPig f)] -> [Literal a] -> Bool
dominates l r = null $ (pos r) \\ (pos l)
    where pos = filter isPos



--finds all minimal non-trivial solutions being carful to never
--pattern match on a solution that we know is not minimal
--minimals' :: [[Literal a]] -> [Literal a] -> Solutions a -> [[Literal a]]
minimals' ss cur (Sat True) | all isNeg cur = ss
                            | otherwise     = cur:ss
minimals' ss cur (Sat False) = ss
minimals' ss cur (Sols i s1 s2) | any (((LPos i):cur) `dominates`) mins = mins
                                | otherwise = minimals' mins ((LPos i):cur) s2
    where mins = minimals' ss ((LNeg i):cur) s1


--finds the trivial solution
trivialSol (Sols i s _) = map ((LNeg i) :) (trivialSol s)
trivialSol (Sat True)   = [[]]
trivialSol (Sat False)  = []


--finds all minimal solutions or the trivial solution if no nontrivial ones
--exist
--minimals :: Solutions a -> [[Literal a]]
minimals sols | null minsols = trivialSol sols
              | otherwise    = minsols
    where minsols = minimals' [] [] sols

--simplifies a term by removing all empties
--simplify :: ACUI f => f a -> f a
simplify e = refoldTerms (unfoldTerm e)


--uses vget to get the term being solved for and converts a solution
--into a substitution
conv :: forall f m a. (Typeable a, Monad m, ACUI f) => m (f a) -> [Literal (AnyPig f)] -> m [Equation f]
conv vget sol = vget >>= \var -> return $ map (convVar var) sol
    where convVar var term = case getVar term of
                                 (AnyPig (term' :: f b))
                                     | isPos term -> case eqT :: Maybe (a :~: b) of
                                                         Just Refl -> term' :=: var
                                     | otherwise  -> term' :=: getId Proxy

subadd :: forall f. (ACUI f) => [Equation f] -> [Equation f] -> [Equation f]
subadd a b = like ++ unlike
    where like = concat [add e1 e2 | e1 <- a, e2 <- b]
          add :: Equation f -> Equation f -> [Equation f]
          add (x :=: (a :: f a)) (y :=: (b :: f b))
              | x =* y = case eqT :: Maybe (a :~: b) of
                             Just Refl -> [x :=: (a `acuiOp` b)]
                             _         -> []
              | otherwise = []
          unlike = filter (not . leftMatches) (a ++ b)
          leftMatches (v :=: _) = any (\(v' :=: _) -> v =* v') like

popVar :: (MonadVar f m, Typeable a) => m (f a)
popVar = do
    v <- freshPig
    return $ unEveryPig v


--solves a homogenous equation
solveHomoEq :: forall f m a. (MonadVar f m, ACUI f, Typeable a) => SimpleEquation [f a] -> m [Equation f]
solveHomoEq eq = do
    let mins = minimals . search . toSatProblem $ eq
    minSols <- mapM (conv (popVar :: m (f a))) mins
    let homosol = foldl subadd [] minSols
    return homosol


--solves an inhomogenous equation for a specific constant
solveInHomoEq :: (MonadVar f m, ACUI f, Typeable a) => f a -> SimpleEquation [f a] -> m [[Equation f]]
solveInHomoEq c eq = do
  let mins = minimals . search . toSatProblem $ eq
  minSols <- mapM (conv (return c)) mins
  return minSols


--finds all solutions to a = b
acuiUnify :: (MonadVar f m, ACUI f, Typeable a) => f a -> f a -> m [[Equation f]]
acuiUnify a b = do
    let l = unfoldTerm a
    let r = unfoldTerm b
    let homo = homogenous (l :==: r)
    homosol <- solveHomoEq homo --solve the homogenous equation
    let inhomos = inhomogenous (l :==: r) --find all inhomogenous equations
    inhomosolss <- mapM (uncurry solveInHomoEq) inhomos --solve each one
    let sols = bigCrossWith subadd [homosol] inhomosolss --combine inhomo sols
    return $ map (map (emap simplify)) sols --simplify the solutions

acuiUnifySys :: (MonadVar f m, ACUI f) => [Equation f] -> m [[Equation f]]
acuiUnifySys ((a :=: b):eqs) = do
    sols <- acuiUnify a b
    let handleSub sub = do
        let eqs' = mapAll (applySub sub) eqs
        sols' <- acuiUnifySys eqs'
        return $ map (sub ++) sols'
    solsBysubs <- mapM handleSub sols
    return $ concat solsBysubs
