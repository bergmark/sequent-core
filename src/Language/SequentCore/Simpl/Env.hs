module Language.SequentCore.Simpl.Env (
  SimplEnv(..), StaticEnv, SimplIdSubst, SubstAns(..), IdDefEnv, Definition(..),
  Guidance(..),

  InCommand, InTerm, InCont, InAlt, InBind,
  InId, InVar, InTyVar, InCoVar,
  OutCommand, OutTerm, OutCont, OutAlt, OutBind,
  OutId, OutVar, OutTyVar, OutCoVar,
  
  mkBoundTo, findDef, setDef,
  initialEnv, mkSuspension, enterScope, enterScopes, mkFreshVar, mkFreshContId,
  substId, substTy, substTyVar, substCo, substCoVar,
  extendIdSubst, zapSubstEnvs, setSubstEnvs, staticPart, setStaticPart,
  inDynamicScope, zapCont, bindCont, bindContAs, pushCont, setCont, retType, restoreEnv,
  
  Floats, emptyFloats, addNonRecFloat, addRecFloats, zapFloats, mapFloats,
  extendFloats, addFloats, wrapFloats, isEmptyFloats, doFloatFromRhs,
  getFloatBinds, getFloats,
  
  termIsHNF, commandIsHNF
) where

import Language.SequentCore.Pretty ()
import Language.SequentCore.Simpl.ExprSize
import Language.SequentCore.Syntax
import Language.SequentCore.Translate

import BasicTypes ( TopLevelFlag(..), RecFlag(..)
                  , isTopLevel, isNotTopLevel, isNonRec )
import Coercion   ( Coercion, CvSubstEnv, CvSubst(..), isCoVar )
import qualified Coercion
import CoreSyn    ( Unfolding(..), UnfoldingGuidance(..), UnfoldingSource(..)
                  , mkOtherCon )
import CoreUnfold ( mkCoreUnfolding, mkDFunUnfolding  )
import DataCon    ( DataCon )
import DynFlags   ( DynFlags, ufCreationThreshold )
import FastString ( FastString, fsLit )
import Id
import IdInfo
import Maybes
import OrdList
import Outputable
import Type       ( Type, TvSubstEnv, TvSubst, mkTvSubst, tyVarsOfType )
import qualified Type
import UniqSupply
import Var
import VarEnv
import VarSet

import Control.Applicative ( (<|>) )
import Control.Exception   ( assert )
import Control.Monad       ( liftM )

infixl 1 `setStaticPart`

data SimplEnv
  = SimplEnv    { se_idSubst :: SimplIdSubst    -- InId    |--> SubstAns (in/out)
                , se_tvSubst :: TvSubstEnv      -- InTyVar |--> OutType
                , se_cvSubst :: CvSubstEnv      -- InCoVar |--> OutCoercion
                , se_retId   :: Maybe ContId
                , se_inScope :: InScopeSet      -- OutVar  |--> OutVar
                , se_defs    :: IdDefEnv        -- OutId   |--> Definition (out)
                , se_floats  :: Floats
                , se_dflags  :: DynFlags }

newtype StaticEnv = StaticEnv SimplEnv -- Ignore se_inScope, se_floats, se_defs

type SimplIdSubst = IdEnv SubstAns -- InId |--> SubstAns
data SubstAns
  = DoneTerm OutTerm
  | DoneId OutId
  | SuspTerm StaticEnv InTerm

-- The original simplifier uses the IdDetails stored in a Var to store unfolding
-- info. We store similar data externally instead. (This is based on the Secrets
-- paper, section 6.3.)
type IdDefEnv = IdEnv Definition
data Definition
  = BoundTo { defTerm :: OutTerm
            , defLevel :: TopLevelFlag
            , defGuidance :: Guidance
            }
  | BoundToDFun { dfunBndrs :: [Var]
                , dfunDataCon :: DataCon
                , dfunArgs :: [OutTerm] }
  | NotAmong [AltCon]

data Guidance
  = Never
  | Usually   { guEvenIfUnsat :: Bool
              , guEvenIfBoring :: Bool } -- currently only used when translated
                                         -- from a Core unfolding
  | Sometimes { guSize :: Int
              , guArgDiscounts :: [Int]
              , guResultDiscount :: Int }

mkBoundTo :: DynFlags -> OutTerm -> TopLevelFlag -> Definition
mkBoundTo dflags term level = BoundTo term level (mkGuidance dflags term)

mkGuidance :: DynFlags -> OutTerm -> Guidance
mkGuidance dflags term
  = let cap = ufCreationThreshold dflags
    in case termSize dflags cap term of
         Nothing -> Never
         Just (ExprSize base args res) ->
           Sometimes base args res

type InCommand  = SeqCoreCommand
type InTerm     = SeqCoreTerm
type InCont     = SeqCoreCont
type InAlt      = SeqCoreAlt
type InBind     = SeqCoreBind
type InId       = Id
type InVar      = Var
type InTyVar    = TyVar
type InCoVar    = CoVar

type OutCommand = SeqCoreCommand
type OutTerm    = SeqCoreTerm
type OutCont    = SeqCoreCont
type OutAlt     = SeqCoreAlt
type OutBind    = SeqCoreBind
type OutId      = Id
type OutVar     = Var
type OutTyVar   = TyVar
type OutCoVar   = CoVar

initialEnv :: DynFlags -> SimplEnv
initialEnv dflags
  = SimplEnv { se_idSubst = emptyVarEnv
             , se_tvSubst = emptyVarEnv
             , se_cvSubst = emptyVarEnv
             , se_retId   = Nothing
             , se_inScope = emptyInScopeSet
             , se_defs    = emptyVarEnv
             , se_floats  = emptyFloats
             , se_dflags  = dflags }

mkSuspension :: StaticEnv -> InTerm -> SubstAns
mkSuspension = SuspTerm

enterScope :: SimplEnv -> InVar -> (SimplEnv, OutVar)
enterScope env x
  = (env', x')
  where
    SimplEnv { se_idSubst = ids, se_tvSubst = tvs, se_cvSubst = cvs
             , se_inScope = ins, se_defs    = defs } = env
    x1    = uniqAway ins x
    x'    = substIdType env x1
    env'  | isTyVar x = env { se_tvSubst = tvs', se_inScope = ins', se_defs = defs' }
          | isCoVar x = env { se_cvSubst = cvs', se_inScope = ins', se_defs = defs' }
          | otherwise = env { se_idSubst = ids', se_inScope = ins', se_defs = defs' }
    ids'  | x' /= x   = extendVarEnv ids x (DoneId x')
          | otherwise = delVarEnv ids x
    tvs'  | x' /= x   = extendVarEnv tvs x (Type.mkTyVarTy x')
          | otherwise = delVarEnv tvs x
    cvs'  | x' /= x   = extendVarEnv cvs x (Coercion.mkCoVarCo x')
          | otherwise = delVarEnv cvs x
    ins'  = extendInScopeSet ins x'
    defs' = delVarEnv defs x'

enterScopes :: SimplEnv -> [InVar] -> (SimplEnv, [OutVar])
enterScopes env []
  = (env, [])
enterScopes env (x : xs)
  = (env'', x' : xs')
  where
    (env', x') = enterScope env x
    (env'', xs') = enterScopes env' xs

mkFreshVar :: MonadUnique m => SimplEnv -> FastString -> Type -> m (SimplEnv, Var)
mkFreshVar env name ty
  = do
    x <- mkSysLocalM name ty
    let x'   = uniqAway (se_inScope env) x
        env' = env { se_inScope = extendInScopeSet (se_inScope env) x' }
    return (env', x')

mkFreshContId :: MonadUnique m => SimplEnv -> FastString -> Type -> m (SimplEnv, ContId)
mkFreshContId env name inTy
  = do
    k <- asContId `liftM` mkSysLocalM name inTy
    let k'   = uniqAway (se_inScope env) k
        env' = env { se_inScope = extendInScopeSet (se_inScope env) k' }
    return (env', k')

substId :: SimplEnv -> InId -> SubstAns
substId (SimplEnv { se_idSubst = ids, se_inScope = ins }) x
  = case lookupVarEnv ids x of
      -- See comments in GHC's SimplEnv.substId for explanations
      Nothing                 -> DoneId (refine ins x)
      Just (DoneId x')        -> DoneId (refine ins x')
      Just (DoneTerm (Var x'))-> DoneId (refine ins x')
      Just ans                -> ans

refine :: InScopeSet -> OutVar -> OutVar
refine ins x
  | isLocalId x
  = case lookupInScope ins x of
      Just x' -> x'
      Nothing -> pprTrace "refine" (text "variable not in scope:" <+> ppr x) x
  | otherwise
  = x

getTvSubst :: SimplEnv -> TvSubst
getTvSubst env = mkTvSubst (se_inScope env) (se_tvSubst env)

substTy :: SimplEnv -> Type -> Type
substTy env t = Type.substTy (getTvSubst env) t

substTyVar :: SimplEnv -> TyVar -> Type
substTyVar env tv = Type.substTyVar (getTvSubst env) tv

substIdType :: SimplEnv -> Var -> Var
substIdType env x
  | isEmptyVarEnv tvs || isEmptyVarSet (tyVarsOfType ty)
  = x
  | otherwise
  = x `setIdType` substTy env ty
  where
    tvs = se_tvSubst env
    ty = idType x

getCvSubst :: SimplEnv -> CvSubst
getCvSubst env = CvSubst (se_inScope env) (se_tvSubst env) (se_cvSubst env)

substCo :: SimplEnv -> Coercion -> Coercion
substCo env co = Coercion.substCo (getCvSubst env) co

substCoVar :: SimplEnv -> CoVar -> Coercion
substCoVar env co = Coercion.substCoVar (getCvSubst env) co

extendIdSubst :: SimplEnv -> InVar -> SubstAns -> SimplEnv
extendIdSubst env x rhs
  = env { se_idSubst = extendVarEnv (se_idSubst env) x rhs }

zapSubstEnvs :: SimplEnv -> SimplEnv
zapSubstEnvs env
  = env { se_idSubst = emptyVarEnv
        , se_tvSubst = emptyVarEnv
        , se_cvSubst = emptyVarEnv
        , se_retId   = Nothing }

setSubstEnvs :: SimplEnv -> SimplIdSubst -> TvSubstEnv -> CvSubstEnv
             -> Maybe ContId -> SimplEnv
setSubstEnvs env ids tvs cvs k
  = env { se_idSubst = ids
        , se_tvSubst = tvs
        , se_cvSubst = cvs
        , se_retId   = k }

bindCont :: MonadUnique m => SimplEnv -> StaticEnv -> InCont -> m SimplEnv
bindCont env stat cont
  = do
    k <- mkSysLocalM (fsLit "k") (contType cont)
    let k' = uniqAway (se_inScope env) k
    return $ bindContAs env k' stat cont

bindContAs :: SimplEnv -> ContId -> StaticEnv -> InCont -> SimplEnv
bindContAs env k stat cont
  = env { se_idSubst = extendVarEnv (se_idSubst env) k
                         (SuspTerm stat (Cont cont))
        , se_retId   = Just k }

pushCont :: MonadUnique m => SimplEnv -> InCont -> m SimplEnv
pushCont env cont
  = bindCont env (staticPart env) cont

zapCont :: SimplEnv -> SimplEnv
zapCont env = env { se_retId = Nothing }

setCont :: SimplEnv -> ContId -> SimplEnv
setCont env k = env { se_retId = Just k }

retType :: SimplEnv -> Type
retType env
  | Just k <- se_retId env
  = case Type.splitFunTy_maybe (idType k) of
      Just (argTy, _) -> substTy env argTy
      Nothing         -> pprPanic "retType" (pprBndr LetBind k)
  | otherwise
  = panic "retType at top level"

staticPart :: SimplEnv -> StaticEnv
staticPart = StaticEnv

setStaticPart :: SimplEnv -> StaticEnv -> SimplEnv
setStaticPart dest (StaticEnv src)
  = dest { se_idSubst = se_idSubst src
         , se_tvSubst = se_tvSubst src
         , se_cvSubst = se_cvSubst src
         , se_retId   = se_retId   src }

inDynamicScope :: StaticEnv -> SimplEnv -> SimplEnv
inDynamicScope = flip setStaticPart

restoreEnv :: SimplEnv -> Maybe (SimplEnv, InCont)
restoreEnv env
  = do
    k <- se_retId env
    substAns <- lookupVarEnv (se_idSubst env) k
    case substAns of
      DoneTerm term -> use (zapSubstEnvs env, term)
      DoneId _ -> Nothing -- not sure what this means, but consistent with prev
      SuspTerm env' term -> use (env' `inDynamicScope` env, term)
      where
        use (env', Cont cont) = Just (env', cont)
        use (_env', term) = pprPanic "restoreEnv" (ppr term)

-- See [Simplifier floats] in SimplEnv

data Floats = Floats (OrdList OutBind) FloatFlag

data FloatFlag
  = FltLifted   -- All bindings are lifted and lazy
                --  Hence ok to float to top level, or recursive

  | FltOkSpec   -- All bindings are FltLifted *or*
                --      strict (perhaps because unlifted,
                --      perhaps because of a strict binder),
                --        *and* ok-for-speculation
                --  Hence ok to float out of the RHS
                --  of a lazy non-recursive let binding
                --  (but not to top level, or into a rec group)

  | FltCareful  -- At least one binding is strict (or unlifted)
                --      and not guaranteed cheap
                --      Do not float these bindings out of a lazy let

andFF :: FloatFlag -> FloatFlag -> FloatFlag
andFF FltCareful _          = FltCareful
andFF FltOkSpec  FltCareful = FltCareful
andFF FltOkSpec  _          = FltOkSpec
andFF FltLifted  flt        = flt

classifyFF :: SeqCoreBind -> FloatFlag
classifyFF (Rec _) = FltLifted
classifyFF (NonRec bndr rhs)
  | not (isStrictId bndr)    = FltLifted
  | termOkForSpeculation rhs = FltOkSpec
  | otherwise                = FltCareful

doFloatFromRhs :: TopLevelFlag -> RecFlag -> Bool -> OutTerm -> SimplEnv -> Bool
-- If you change this function look also at FloatIn.noFloatFromRhs
doFloatFromRhs lvl rc str rhs (SimplEnv {se_floats = Floats fs ff})
  =  not (isNilOL fs) && want_to_float && can_float
  where
     want_to_float = isTopLevel lvl || termIsCheap rhs || termIsExpandable rhs 
                     -- See Note [Float when cheap or expandable]
     can_float = case ff of
                   FltLifted  -> True
                   FltOkSpec  -> isNotTopLevel lvl && isNonRec rc
                   FltCareful -> isNotTopLevel lvl && isNonRec rc && str

emptyFloats :: Floats
emptyFloats = Floats nilOL FltLifted

unitFloat :: OutBind -> Floats
unitFloat bind = Floats (unitOL bind) (classifyFF bind)

addNonRecFloat :: SimplEnv -> OutId -> OutTerm -> SimplEnv
addNonRecFloat env id rhs
  = id `seq`   -- This seq forces the Id, and hence its IdInfo,
               -- and hence any inner substitutions
    env { se_floats = se_floats env `addFlts` unitFloat (NonRec id rhs),
          se_inScope = extendInScopeSet (se_inScope env) id }

mapFloats :: SimplEnv -> ((OutId, OutTerm) -> (OutId, OutTerm)) -> SimplEnv
mapFloats env@SimplEnv { se_floats = Floats fs ff } fun
   = env { se_floats = Floats (mapOL app fs) ff }
   where
     app (NonRec b e) = case fun (b,e) of (b',e') -> NonRec b' e'
     app (Rec bs)     = Rec (map fun bs)

extendFloats :: SimplEnv -> OutBind -> SimplEnv
-- Add these bindings to the floats, and extend the in-scope env too
extendFloats env bind
  = env { se_floats  = se_floats env `addFlts` unitFloat bind,
          se_inScope = extendInScopeSetList (se_inScope env) bndrs,
          se_defs    = extendVarEnvList (se_defs env) defs}
  where
    bndrs = bindersOf bind
    defs = map asDef (flattenBind bind)
    -- FIXME The NotTopLevel flag might wind up being wrong!
    asDef (x, term) = (x, mkBoundTo (se_dflags env) term NotTopLevel)

addFloats :: SimplEnv -> SimplEnv -> SimplEnv
-- Add the floats for env2 to env1;
-- *plus* the in-scope set for env2, which is bigger
-- than that for env1
addFloats env1 env2
  = env1 {se_floats = se_floats env1 `addFlts` se_floats env2,
          se_inScope = se_inScope env2,
          se_defs = se_defs env2 }

wrapFloats :: SimplEnv -> OutCommand -> OutCommand
wrapFloats env cmd = foldrOL wrap cmd (floatBinds (se_floats env))
  where
    wrap :: OutBind -> OutCommand -> OutCommand
    wrap bind@(Rec {}) cmd = cmd { cmdLet = bind : cmdLet cmd }
    wrap (NonRec b r)  cmd = addNonRec b r cmd

addFlts :: Floats -> Floats -> Floats
addFlts (Floats bs1 l1) (Floats bs2 l2)
  = Floats (bs1 `appOL` bs2) (l1 `andFF` l2)

zapFloats :: SimplEnv -> SimplEnv
zapFloats env = env { se_floats = emptyFloats }

addRecFloats :: SimplEnv -> SimplEnv -> SimplEnv
-- Flattens the floats from env2 into a single Rec group,
-- prepends the floats from env1, and puts the result back in env2
-- This is all very specific to the way recursive bindings are
-- handled; see Simpl.simplRecBind
addRecFloats env1 env2@(SimplEnv {se_floats = Floats bs ff})
  = assert (case ff of { FltLifted -> True; _ -> False })
  $ env2 {se_floats = se_floats env1 `addFlts` unitFloat (Rec (flattenBinds (fromOL bs)))}

getFloatBinds :: Floats -> [OutBind]
getFloatBinds = fromOL . floatBinds

floatBinds :: Floats -> OrdList OutBind
floatBinds (Floats bs _) = bs

getFloats :: SimplEnv -> Floats
getFloats = se_floats

isEmptyFloats :: SimplEnv -> Bool
isEmptyFloats = isNilOL . floatBinds . se_floats

findDef :: SimplEnv -> OutId -> Maybe Definition
findDef env var
  = lookupVarEnv (se_defs env) var <|> unfoldingToDef (unfoldingInfo (idInfo var))

unfoldingToDef :: Unfolding -> Maybe Definition
unfoldingToDef NoUnfolding     = Nothing
unfoldingToDef (OtherCon cons) = Just (NotAmong cons)
unfoldingToDef unf@(CoreUnfolding {})
  = Just $ BoundTo { defTerm     = termFromCoreExpr (uf_tmpl unf)
                   , defLevel    = if uf_is_top unf then TopLevel else NotTopLevel
                   , defGuidance = unfGuidanceToGuidance (uf_guidance unf) }
unfoldingToDef unf@(DFunUnfolding {})
  = Just $ BoundToDFun { dfunBndrs    = df_bndrs unf
                       , dfunDataCon  = df_con unf
                       , dfunArgs     = map termFromCoreExpr (df_args unf) }

unfGuidanceToGuidance :: UnfoldingGuidance -> Guidance
unfGuidanceToGuidance UnfNever = Never
unfGuidanceToGuidance (UnfWhen { ug_unsat_ok = unsat , ug_boring_ok = boring })
  = Usually { guEvenIfUnsat = unsat , guEvenIfBoring = boring }
unfGuidanceToGuidance (UnfIfGoodArgs { ug_args = args, ug_size = size, ug_res = res })
  = Sometimes { guSize = size, guArgDiscounts = args, guResultDiscount = res }

setDef :: SimplEnv -> OutId -> Definition -> (SimplEnv, OutId)
setDef env x def
  = (env', x')
  where
    env' = env { se_inScope = extendInScopeSet (se_inScope env) x'
               , se_defs    = extendVarEnv (se_defs env) x' def }
    x'   | DFunUnfolding {} <- idUnfolding x = x -- don't mess with these since
                                                 -- we don't generate them
         | otherwise = x `setIdUnfolding` defToUnfolding def

defToUnfolding :: Definition -> Unfolding
defToUnfolding (NotAmong cons) = mkOtherCon cons
defToUnfolding (BoundTo { defTerm = Cont {} })
  = NoUnfolding -- TODO Can we do better? Translating requires knowing the outer linear cont.
defToUnfolding (BoundTo { defTerm = term, defLevel = lev, defGuidance = guid })
  = mkCoreUnfolding InlineRhs (isTopLevel lev) (termToCoreExpr term)
      (termArity term) (guidanceToUnfGuidance guid)
defToUnfolding (BoundToDFun { dfunBndrs = bndrs, dfunDataCon = con, dfunArgs = args})
  = mkDFunUnfolding bndrs con (map termToCoreExpr args)

guidanceToUnfGuidance :: Guidance -> UnfoldingGuidance
guidanceToUnfGuidance Never = UnfNever
guidanceToUnfGuidance (Usually { guEvenIfUnsat = unsat, guEvenIfBoring = boring })
  = UnfWhen { ug_unsat_ok = unsat, ug_boring_ok = boring }
guidanceToUnfGuidance (Sometimes { guSize = size, guArgDiscounts = args, guResultDiscount = res})
  = UnfIfGoodArgs { ug_size = size, ug_args = args, ug_res = res }

-- TODO This might be in Syntax, but since we're not storing our "unfoldings" in
-- ids, we rely on the environment to tell us whether a variable has been
-- evaluated.

termIsHNF :: SimplEnv -> SeqCoreTerm -> Bool
termIsHNF _   (Lit {})  = True
termIsHNF _   (Cons {}) = True
termIsHNF env (Var id)
  = case lookupVarEnv (se_defs env) id of
      Just (NotAmong {})      -> True
      Just (BoundTo term _ _) -> termIsHNF env term
      _                       -> False
termIsHNF env (Compute _ comm) = commandIsHNF env comm
termIsHNF _   _        = False

commandIsHNF :: SimplEnv -> SeqCoreCommand -> Bool
commandIsHNF _env (Command [] (Var fid) cont)
  | let (args, _) = collectArgs cont
  , length args < idArity fid
  = True
commandIsHNF _env (Command _ (Compute {}) _)
  = False
commandIsHNF env (Command [] term (Return _))
  = termIsHNF env term
commandIsHNF _ _
  = False

instance Outputable SimplEnv where
  ppr (SimplEnv ids tvs cvs cont in_scope _defs floats _dflags)
    =  text "<InScope =" <+> braces (fsep (map ppr (varEnvElts (getInScopeVars in_scope))))
--    $$ text " Defs      =" <+> ppr defs
    $$ text " IdSubst   =" <+> ppr ids
    $$ text " TvSubst   =" <+> ppr tvs
    $$ text " CvSubst   =" <+> ppr cvs
    $$ text " RetId     =" <+> ppr cont
    $$ text " Floats    =" <+> ppr floatBndrs
     <> char '>'
    where
      floatBndrs = bindersOfBinds (getFloatBinds floats)

instance Outputable StaticEnv where
  ppr (StaticEnv (SimplEnv ids tvs cvs cont _in_scope _defs _floats _dflags))
    =  text "<IdSubst   =" <+> ppr ids
    $$ text " TvSubst   =" <+> ppr tvs
    $$ text " CvSubst   =" <+> ppr cvs
    $$ text " RetId     =" <+> ppr cont
     <> char '>'

instance Outputable SubstAns where
  ppr (DoneTerm v) = brackets (text "Term:" <+> ppr v)
  ppr (DoneId x) = brackets (text "Id:" <+> ppr x)
  ppr (SuspTerm _ term@(Cont (Return _))) = brackets (text "Suspended:" <+> ppr term)
  ppr (SuspTerm {}) = text "Suspended"
--  ppr (SuspTerm _env v)
--    = brackets $ hang (text "Suspended:") 2 (ppr v)

instance Outputable Definition where
  ppr (BoundTo c level guid)
    = sep [brackets (ppr level <+> ppr guid), ppr c]
  ppr (BoundToDFun bndrs con args)
    = char '\\' <+> hsep (map ppr bndrs) <+> arrow <+> ppr con <+> hsep (map (parens . ppr) args)
  ppr (NotAmong alts) = text "NotAmong" <+> ppr alts

instance Outputable Guidance where
  ppr Never = text "Never"
  ppr (Usually unsatOk boringOk)
    = text "Usually" <+> brackets (hsep $ punctuate comma $ catMaybes
                                    [if unsatOk then Just (text "even if unsat") else Nothing,
                                     if boringOk then Just (text "even if boring cxt") else Nothing])
  ppr (Sometimes base argDiscs resDisc)
    = text "Sometimes" <+> brackets (int base <+> ppr argDiscs <+> int resDisc)

instance Outputable Floats where
  ppr (Floats binds ff) = ppr ff $$ ppr (fromOL binds)

instance Outputable FloatFlag where
  ppr FltLifted = text "FltLifted"
  ppr FltOkSpec = text "FltOkSpec"
  ppr FltCareful = text "FltCareful"
