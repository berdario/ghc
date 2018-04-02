{-
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[RnSource]{Main pass of renamer}
-}

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}

module RnTypes (
        -- Type related stuff
        rnHsType, rnLHsType, rnLHsTypes, rnContext,
        rnHsKind, rnLHsKind,
        rnHsSigType, rnHsWcType,
        rnHsSigWcType, rnHsSigWcTypeScoped,
        rnLHsInstType,
        newTyVarNameRn, collectAnonWildCards,
        rnConDeclFields,
        rnLTyVar,

        -- Precence related stuff
        mkOpAppRn, mkNegAppRn, mkOpFormRn, mkConOpPatRn,
        checkPrecMatch, checkSectionPrec,

        -- Binding related stuff
        bindLHsTyVarBndr, bindLHsTyVarBndrs, rnImplicitBndrs,
        bindSigTyVarsFV, bindHsQTyVars, bindLRdrNames,
        extractFilteredRdrTyVars, extractFilteredRdrTyVarsDups,
        extractHsTyRdrTyVars, extractHsTyRdrTyVarsKindVars,
        extractHsTyRdrTyVarsDups, extractHsTysRdrTyVars,
        extractHsTysRdrTyVarsDups, rmDupsInRdrTyVars,
        extractRdrKindSigVars, extractDataDefnKindVars,
        extractHsTvBndrs,
        freeKiTyVarsAllVars, freeKiTyVarsKindVars, freeKiTyVarsTypeVars,
        elemRdr
  ) where

import GhcPrelude

import {-# SOURCE #-} RnSplice( rnSpliceType )

import DynFlags
import HsSyn
import RnHsDoc          ( rnLHsDoc, rnMbLHsDoc )
import RnEnv
import RnUnbound        ( perhapsForallMsg )
import RnUtils          ( HsDocContext(..), withHsDocContext, mapFvRn
                        , pprHsDocContext, bindLocalNamesFV
                        , newLocalBndrRn, checkDupRdrNames, checkShadowedRdrNames )
import RnFixity         ( lookupFieldFixityRn, lookupFixityRn
                        , lookupTyFixityRn )
import TcRnMonad
import RdrName
import PrelNames
import TysPrim          ( funTyConName )
import TysWiredIn       ( starKindTyConName, unicodeStarKindTyConName )
import Name
import SrcLoc
import NameSet
import FieldLabel

import Util
import ListSetOps       ( deleteBys )
import BasicTypes       ( compareFixity, funTyFixity, negateFixity,
                          Fixity(..), FixityDirection(..), LexicalFixity(..) )
import Outputable
import FastString
import Maybes
import qualified GHC.LanguageExtensions as LangExt

import Data.List          ( nubBy, partition, (\\) )
import Control.Monad      ( unless, when )

#include "HsVersions.h"

{-
These type renamers are in a separate module, rather than in (say) RnSource,
to break several loop.

*********************************************************
*                                                       *
           HsSigWcType (i.e with wildcards)
*                                                       *
*********************************************************
-}

rnHsSigWcType :: HsDocContext -> LHsSigWcType GhcPs
            -> RnM (LHsSigWcType GhcRn, FreeVars)
rnHsSigWcType doc sig_ty
  = rn_hs_sig_wc_type False doc sig_ty $ \sig_ty' ->
    return (sig_ty', emptyFVs)

rnHsSigWcTypeScoped :: HsDocContext -> LHsSigWcType GhcPs
                    -> (LHsSigWcType GhcRn -> RnM (a, FreeVars))
                    -> RnM (a, FreeVars)
-- Used for
--   - Signatures on binders in a RULE
--   - Pattern type signatures
-- Wildcards are allowed
-- type signatures on binders only allowed with ScopedTypeVariables
rnHsSigWcTypeScoped ctx sig_ty thing_inside
  = do { ty_sig_okay <- xoptM LangExt.ScopedTypeVariables
       ; checkErr ty_sig_okay (unexpectedTypeSigErr sig_ty)
       ; rn_hs_sig_wc_type True ctx sig_ty thing_inside
       }
    -- True: for pattern type sigs and rules we /do/ want
    --       to bring those type variables into scope, even
    --       if there's a forall at the top which usually
    --       stops that happening
    -- e.g  \ (x :: forall a. a-> b) -> e
    -- Here we do bring 'b' into scope

rn_hs_sig_wc_type :: Bool   -- True <=> always bind any free tyvars of the
                            --          type, regardless of whether it has
                            --          a forall at the top
                  -> HsDocContext
                  -> LHsSigWcType GhcPs
                  -> (LHsSigWcType GhcRn -> RnM (a, FreeVars))
                  -> RnM (a, FreeVars)
-- rn_hs_sig_wc_type is used for source-language type signatures
rn_hs_sig_wc_type always_bind_free_tvs ctxt
                  (HsWC { hswc_body = HsIB { hsib_body = hs_ty }})
                  thing_inside
  = do { free_vars <- extractFilteredRdrTyVarsDups hs_ty
       ; (tv_rdrs, nwc_rdrs') <- partition_nwcs free_vars
       ; let nwc_rdrs = nubL nwc_rdrs'
             bind_free_tvs = always_bind_free_tvs || not (isLHsForAllTy hs_ty)
       ; rnImplicitBndrs bind_free_tvs ctxt tv_rdrs $ \ vars ->
    do { (wcs, hs_ty', fvs1) <- rnWcBody ctxt nwc_rdrs hs_ty
       ; let sig_ty' = HsWC { hswc_wcs = wcs, hswc_body = ib_ty' }
             ib_ty'  = mk_implicit_bndrs vars hs_ty' fvs1
       ; (res, fvs2) <- thing_inside sig_ty'
       ; return (res, fvs1 `plusFV` fvs2) } }

rnHsWcType :: HsDocContext -> LHsWcType GhcPs -> RnM (LHsWcType GhcRn, FreeVars)
rnHsWcType ctxt (HsWC { hswc_body = hs_ty })
  = do { free_vars <- extractFilteredRdrTyVars hs_ty
       ; (_, nwc_rdrs) <- partition_nwcs free_vars
       ; (wcs, hs_ty', fvs) <- rnWcBody ctxt nwc_rdrs hs_ty
       ; let sig_ty' = HsWC { hswc_wcs = wcs, hswc_body = hs_ty' }
       ; return (sig_ty', fvs) }

rnWcBody :: HsDocContext -> [Located RdrName] -> LHsType GhcPs
         -> RnM ([Name], LHsType GhcRn, FreeVars)
rnWcBody ctxt nwc_rdrs hs_ty
  = do { nwcs <- mapM newLocalBndrRn nwc_rdrs
       ; let env = RTKE { rtke_level = TypeLevel
                        , rtke_what  = RnTypeBody
                        , rtke_nwcs  = mkNameSet nwcs
                        , rtke_ctxt  = ctxt }
       ; (hs_ty', fvs) <- bindLocalNamesFV nwcs $
                          rn_lty env hs_ty
       ; let awcs = collectAnonWildCards hs_ty'
       ; return (nwcs ++ awcs, hs_ty', fvs) }
  where
    rn_lty env (L loc hs_ty)
      = setSrcSpan loc $
        do { (hs_ty', fvs) <- rn_ty env hs_ty
           ; return (L loc hs_ty', fvs) }

    rn_ty :: RnTyKiEnv -> HsType GhcPs -> RnM (HsType GhcRn, FreeVars)
    -- A lot of faff just to allow the extra-constraints wildcard to appear
    rn_ty env hs_ty@(HsForAllTy { hst_bndrs = tvs, hst_body = hs_body })
      = bindLHsTyVarBndrs (rtke_ctxt env) (Just $ inTypeDoc hs_ty) Nothing tvs $ \ tvs' ->
        do { (hs_body', fvs) <- rn_lty env hs_body
           ; return (HsForAllTy { hst_xforall = noExt, hst_bndrs = tvs'
                                , hst_body = hs_body' }, fvs) }

    rn_ty env (HsQualTy { hst_ctxt = L cx hs_ctxt, hst_body = hs_ty })
      | Just (hs_ctxt1, hs_ctxt_last) <- snocView hs_ctxt
      , L lx (HsWildCardTy _)  <- ignoreParens hs_ctxt_last
      = do { (hs_ctxt1', fvs1) <- mapFvRn (rn_top_constraint env) hs_ctxt1
           ; wc' <- setSrcSpan lx $
                    do { checkExtraConstraintWildCard env hs_ctxt1
                       ; rnAnonWildCard }
           ; let hs_ctxt' = hs_ctxt1' ++ [L lx (HsWildCardTy wc')]
           ; (hs_ty', fvs2) <- rnLHsTyKi env hs_ty
           ; return (HsQualTy { hst_xqual = noExt
                              , hst_ctxt = L cx hs_ctxt', hst_body = hs_ty' }
                    , fvs1 `plusFV` fvs2) }

      | otherwise
      = do { (hs_ctxt', fvs1) <- mapFvRn (rn_top_constraint env) hs_ctxt
           ; (hs_ty', fvs2)   <- rnLHsTyKi env hs_ty
           ; return (HsQualTy { hst_xqual = noExt
                              , hst_ctxt = L cx hs_ctxt', hst_body = hs_ty' }
                    , fvs1 `plusFV` fvs2) }

    rn_ty env hs_ty = rnHsTyKi env hs_ty

    rn_top_constraint env = rnLHsTyKi (env { rtke_what = RnTopConstraint })


checkExtraConstraintWildCard :: RnTyKiEnv -> HsContext GhcPs -> RnM ()
-- Rename the extra-constraint spot in a type signature
--    (blah, _) => type
-- Check that extra-constraints are allowed at all, and
-- if so that it's an anonymous wildcard
checkExtraConstraintWildCard env hs_ctxt
  = checkWildCard env mb_bad
  where
    mb_bad | not (extraConstraintWildCardsAllowed env)
           = Just base_msg
             -- Currently, we do not allow wildcards in their full glory in
             -- standalone deriving declarations. We only allow a single
             -- extra-constraints wildcard à la:
             --
             --   deriving instance _ => Eq (Foo a)
             --
             -- i.e., we don't support things like
             --
             --   deriving instance (Eq a, _) => Eq (Foo a)
           | DerivDeclCtx {} <- rtke_ctxt env
           , not (null hs_ctxt)
           = Just deriv_decl_msg
           | otherwise
           = Nothing

    base_msg = text "Extra-constraint wildcard" <+> quotes pprAnonWildCard
                   <+> text "not allowed"

    deriv_decl_msg
      = hang base_msg
           2 (vcat [ text "except as the sole constraint"
                   , nest 2 (text "e.g., deriving instance _ => Eq (Foo a)") ])

extraConstraintWildCardsAllowed :: RnTyKiEnv -> Bool
extraConstraintWildCardsAllowed env
  = case rtke_ctxt env of
      TypeSigCtx {}       -> True
      ExprWithTySigCtx {} -> True
      DerivDeclCtx {}     -> True
      _                   -> False

-- | Finds free type and kind variables in a type,
--     without duplicates, and
--     without variables that are already in scope in LocalRdrEnv
--   NB: this includes named wildcards, which look like perfectly
--       ordinary type variables at this point
extractFilteredRdrTyVars :: LHsType GhcPs -> RnM FreeKiTyVarsNoDups
extractFilteredRdrTyVars hs_ty
  = do { rdr_env <- getLocalRdrEnv
       ; filterInScope rdr_env <$> extractHsTyRdrTyVars hs_ty }

-- | Finds free type and kind variables in a type,
--     with duplicates, but
--     without variables that are already in scope in LocalRdrEnv
--   NB: this includes named wildcards, which look like perfectly
--       ordinary type variables at this point
extractFilteredRdrTyVarsDups :: LHsType GhcPs -> RnM FreeKiTyVarsWithDups
extractFilteredRdrTyVarsDups hs_ty
  = do { rdr_env <- getLocalRdrEnv
       ; filterInScope rdr_env <$> extractHsTyRdrTyVarsDups hs_ty }

-- | When the NamedWildCards extension is enabled, partition_nwcs
-- removes type variables that start with an underscore from the
-- FreeKiTyVars in the argument and returns them in a separate list.
-- When the extension is disabled, the function returns the argument
-- and empty list.  See Note [Renaming named wild cards]
partition_nwcs :: FreeKiTyVars -> RnM (FreeKiTyVars, [Located RdrName])
partition_nwcs free_vars@(FKTV { fktv_tys = tys })
  = do { wildcards_enabled <- fmap (xopt LangExt.NamedWildCards) getDynFlags
       ; let (nwcs, no_nwcs) | wildcards_enabled = partition is_wildcard tys
                             | otherwise         = ([], tys)
             free_vars' = free_vars { fktv_tys = no_nwcs }
       ; return (free_vars', nwcs) }
  where
     is_wildcard :: Located RdrName -> Bool
     is_wildcard rdr = startsWithUnderscore (rdrNameOcc (unLoc rdr))

{- Note [Renaming named wild cards]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Identifiers starting with an underscore are always parsed as type variables.
It is only here in the renamer that we give the special treatment.
See Note [The wildcard story for types] in HsTypes.

It's easy!  When we collect the implicitly bound type variables, ready
to bring them into scope, and NamedWildCards is on, we partition the
variables into the ones that start with an underscore (the named
wildcards) and the rest. Then we just add them to the hswc_wcs field
of the HsWildCardBndrs structure, and we are done.


*********************************************************
*                                                       *
           HsSigtype (i.e. no wildcards)
*                                                       *
****************************************************** -}

rnHsSigType :: HsDocContext -> LHsSigType GhcPs
            -> RnM (LHsSigType GhcRn, FreeVars)
-- Used for source-language type signatures
-- that cannot have wildcards
rnHsSigType ctx (HsIB { hsib_body = hs_ty })
  = do { traceRn "rnHsSigType" (ppr hs_ty)
       ; vars <- extractFilteredRdrTyVarsDups hs_ty
       ; rnImplicitBndrs (not (isLHsForAllTy hs_ty)) ctx vars $ \ vars ->
    do { (body', fvs) <- rnLHsType ctx hs_ty
       ; return ( mk_implicit_bndrs vars body' fvs, fvs ) } }

rnImplicitBndrs :: Bool    -- True <=> bring into scope any free type variables
                           -- E.g.  f :: forall a. a->b
                           --  we do not want to bring 'b' into scope, hence False
                           -- But   f :: a -> b
                           --  we want to bring both 'a' and 'b' into scope
                -> HsDocContext
                -> FreeKiTyVarsWithDups
                                   -- Free vars of hs_ty (excluding wildcards)
                                   -- May have duplicates, which is
                                   -- checked here
                -> ([Name] -> RnM (a, FreeVars))
                -> RnM (a, FreeVars)
rnImplicitBndrs bind_free_tvs doc
                fvs_with_dups@(FKTV { fktv_kis = kvs_with_dups
                                    , fktv_tys = tvs_with_dups })
                thing_inside
  = do { let FKTV kvs tvs = rmDupsInRdrTyVars fvs_with_dups
             real_tvs | bind_free_tvs = tvs
                      | otherwise     = []
             -- We always bind over free /kind/ variables.
             -- Bind free /type/ variables only if there is no
             -- explicit forall.  E.g.
             --    f :: Proxy (a :: k) -> b
             --         Quantify over {k} and {a,b}
             --    g :: forall a. Proxy (a :: k) -> b
             --         Quantify over {k} and {}
             -- Note that we always do the implicit kind-quantification
             -- but, rather arbitrarily, we switch off the type-quantification
             -- if there is an explicit forall

       ; traceRn "rnImplicitBndrs" (vcat [ ppr kvs, ppr tvs, ppr real_tvs ])

       ; loc <- getSrcSpanM
       ; vars <- mapM (newLocalBndrRn . L loc . unLoc) (kvs ++ real_tvs)

       ; checkBadKindBndrs doc kvs

       ; traceRn "checkMixedVars2" $
           vcat [ text "kvs_with_dups" <+> ppr kvs_with_dups
                , text "tvs_with_dups" <+> ppr tvs_with_dups ]
       ; checkMixedVars kvs_with_dups tvs_with_dups
           -- E.g.  Either (Proxy (a :: k)) k
           -- Here 'k' is used at kind level and type level

       ; bindLocalNamesFV vars $
         thing_inside vars }

rnLHsInstType :: SDoc -> LHsSigType GhcPs -> RnM (LHsSigType GhcRn, FreeVars)
-- Rename the type in an instance.
-- The 'doc_str' is "an instance declaration" or "a VECTORISE pragma"
-- Do not try to decompose the inst_ty in case it is malformed
rnLHsInstType doc inst_ty = rnHsSigType (GenericCtx doc) inst_ty

mk_implicit_bndrs :: [Name]  -- implicitly bound
                  -> a           -- payload
                  -> FreeVars    -- FreeVars of payload
                  -> HsImplicitBndrs GhcRn a
mk_implicit_bndrs vars body fvs
  = HsIB { hsib_vars = vars
         , hsib_body = body
         , hsib_closed = nameSetAll (not . isTyVarName) (vars `delFVs` fvs) }



{- ******************************************************
*                                                       *
           LHsType and HsType
*                                                       *
****************************************************** -}

{-
rnHsType is here because we call it from loadInstDecl, and I didn't
want a gratuitous knot.

Note [Context quantification]
-----------------------------
Variables in type signatures are implicitly quantified
when (1) they are in a type signature not beginning
with "forall" or (2) in any qualified type T => R.
We are phasing out (2) since it leads to inconsistencies
(Trac #4426):

data A = A (a -> a)           is an error
data A = A (Eq a => a -> a)   binds "a"
data A = A (Eq a => a -> b)   binds "a" and "b"
data A = A (() => a -> b)     binds "a" and "b"
f :: forall a. a -> b         is an error
f :: forall a. () => a -> b   is an error
f :: forall a. a -> (() => b) binds "a" and "b"

This situation is now considered to be an error. See rnHsTyKi for case
HsForAllTy Qualified.

Note [Dealing with *]
~~~~~~~~~~~~~~~~~~~~~
As a legacy from the days when types and kinds were different, we use
the type * to mean what we now call GHC.Types.Type. The problem is that
* should associate just like an identifier, *not* a symbol.
Running example: the user has written

  T (Int, Bool) b + c * d

At this point, we have a bunch of stretches of types

  [[T, (Int, Bool), b], [c], [d]]

these are the [[LHsType Name]] and a bunch of operators

  [GHC.TypeLits.+, GHC.Types.*]

Note that the * is GHC.Types.*. So, we want to rearrange to have

  [[T, (Int, Bool), b], [c, *, d]]

and

  [GHC.TypeLits.+]

as our lists. We can then do normal fixity resolution on these. The fixities
must come along for the ride just so that the list stays in sync with the
operators.

Note [QualTy in kinds]
~~~~~~~~~~~~~~~~~~~~~~
I was wondering whether QualTy could occur only at TypeLevel.  But no,
we can have a qualified type in a kind too. Here is an example:

  type family F a where
    F Bool = Nat
    F Nat  = Type

  type family G a where
    G Type = Type -> Type
    G ()   = Nat

  data X :: forall k1 k2. (F k1 ~ G k2) => k1 -> k2 -> Type where
    MkX :: X 'True '()

See that k1 becomes Bool and k2 becomes (), so the equality is
satisfied. If I write MkX :: X 'True 'False, compilation fails with a
suitable message:

  MkX :: X 'True '()
    • Couldn't match kind ‘G Bool’ with ‘Nat’
      Expected kind: G Bool
        Actual kind: F Bool

However: in a kind, the constraints in the QualTy must all be
equalities; or at least, any kinds with a class constraint are
uninhabited.
-}

data RnTyKiEnv
  = RTKE { rtke_ctxt  :: HsDocContext
         , rtke_level :: TypeOrKind  -- Am I renaming a type or a kind?
         , rtke_what  :: RnTyKiWhat  -- And within that what am I renaming?
         , rtke_nwcs  :: NameSet     -- These are the in-scope named wildcards
    }

data RnTyKiWhat = RnTypeBody
                | RnTopConstraint   -- Top-level context of HsSigWcTypes
                | RnConstraint      -- All other constraints

instance Outputable RnTyKiEnv where
  ppr (RTKE { rtke_level = lev, rtke_what = what
            , rtke_nwcs = wcs, rtke_ctxt = ctxt })
    = text "RTKE"
      <+> braces (sep [ ppr lev, ppr what, ppr wcs
                      , pprHsDocContext ctxt ])

instance Outputable RnTyKiWhat where
  ppr RnTypeBody      = text "RnTypeBody"
  ppr RnTopConstraint = text "RnTopConstraint"
  ppr RnConstraint    = text "RnConstraint"

mkTyKiEnv :: HsDocContext -> TypeOrKind -> RnTyKiWhat -> RnTyKiEnv
mkTyKiEnv cxt level what
 = RTKE { rtke_level = level, rtke_nwcs = emptyNameSet
        , rtke_what = what, rtke_ctxt = cxt }

isRnKindLevel :: RnTyKiEnv -> Bool
isRnKindLevel (RTKE { rtke_level = KindLevel }) = True
isRnKindLevel _                                 = False

--------------
rnLHsType  :: HsDocContext -> LHsType GhcPs -> RnM (LHsType GhcRn, FreeVars)
rnLHsType ctxt ty = rnLHsTyKi (mkTyKiEnv ctxt TypeLevel RnTypeBody) ty

rnLHsTypes :: HsDocContext -> [LHsType GhcPs] -> RnM ([LHsType GhcRn], FreeVars)
rnLHsTypes doc tys = mapFvRn (rnLHsType doc) tys

rnHsType  :: HsDocContext -> HsType GhcPs -> RnM (HsType GhcRn, FreeVars)
rnHsType ctxt ty = rnHsTyKi (mkTyKiEnv ctxt TypeLevel RnTypeBody) ty

rnLHsKind  :: HsDocContext -> LHsKind GhcPs -> RnM (LHsKind GhcRn, FreeVars)
rnLHsKind ctxt kind = rnLHsTyKi (mkTyKiEnv ctxt KindLevel RnTypeBody) kind

rnHsKind  :: HsDocContext -> HsKind GhcPs -> RnM (HsKind GhcRn, FreeVars)
rnHsKind ctxt kind = rnHsTyKi  (mkTyKiEnv ctxt KindLevel RnTypeBody) kind

--------------
rnTyKiContext :: RnTyKiEnv -> LHsContext GhcPs
              -> RnM (LHsContext GhcRn, FreeVars)
rnTyKiContext env (L loc cxt)
  = do { traceRn "rncontext" (ppr cxt)
       ; let env' = env { rtke_what = RnConstraint }
       ; (cxt', fvs) <- mapFvRn (rnLHsTyKi env') cxt
       ; return (L loc cxt', fvs) }

rnContext :: HsDocContext -> LHsContext GhcPs
          -> RnM (LHsContext GhcRn, FreeVars)
rnContext doc theta = rnTyKiContext (mkTyKiEnv doc TypeLevel RnConstraint) theta

--------------
rnLHsTyKi  :: RnTyKiEnv -> LHsType GhcPs -> RnM (LHsType GhcRn, FreeVars)
rnLHsTyKi env (L loc ty)
  = setSrcSpan loc $
    do { (ty', fvs) <- rnHsTyKi env ty
       ; return (L loc ty', fvs) }

rnHsTyKi :: RnTyKiEnv -> HsType GhcPs -> RnM (HsType GhcRn, FreeVars)

rnHsTyKi env ty@(HsForAllTy { hst_bndrs = tyvars, hst_body  = tau })
  = do { checkTypeInType env ty
       ; bindLHsTyVarBndrs (rtke_ctxt env) (Just $ inTypeDoc ty)
                           Nothing tyvars $ \ tyvars' ->
    do { (tau',  fvs) <- rnLHsTyKi env tau
       ; return ( HsForAllTy { hst_xforall = noExt, hst_bndrs = tyvars'
                             , hst_body =  tau' }
                , fvs) } }

rnHsTyKi env ty@(HsQualTy { hst_ctxt = lctxt, hst_body = tau })
  = do { checkTypeInType env ty  -- See Note [QualTy in kinds]
       ; (ctxt', fvs1) <- rnTyKiContext env lctxt
       ; (tau',  fvs2) <- rnLHsTyKi env tau
       ; return (HsQualTy { hst_xqual = noExt, hst_ctxt = ctxt'
                          , hst_body =  tau' }
                , fvs1 `plusFV` fvs2) }

rnHsTyKi env (HsTyVar _ ip (L loc rdr_name))
  = do { name <- rnTyVar env rdr_name
       ; return (HsTyVar noExt ip (L loc name), unitFV name) }

rnHsTyKi env ty@(HsOpTy _ ty1 l_op ty2)
  = setSrcSpan (getLoc l_op) $
    do  { (l_op', fvs1) <- rnHsTyOp env ty l_op
        ; fix   <- lookupTyFixityRn l_op'
        ; (ty1', fvs2) <- rnLHsTyKi env ty1
        ; (ty2', fvs3) <- rnLHsTyKi env ty2
        ; res_ty <- mkHsOpTyRn (\t1 t2 -> HsOpTy noExt t1 l_op' t2)
                               (unLoc l_op') fix ty1' ty2'
        ; return (res_ty, plusFVs [fvs1, fvs2, fvs3]) }

rnHsTyKi env (HsParTy _ ty)
  = do { (ty', fvs) <- rnLHsTyKi env ty
       ; return (HsParTy noExt ty', fvs) }

rnHsTyKi env (HsBangTy _ b ty)
  = do { (ty', fvs) <- rnLHsTyKi env ty
       ; return (HsBangTy noExt b ty', fvs) }
rnHsTyKi env ty@(HsRecTy _ flds)
  = do { let ctxt = rtke_ctxt env
       ; fls          <- get_fields ctxt
       ; (flds', fvs) <- rnConDeclFields ctxt fls flds
       ; return (HsRecTy noExt flds', fvs) }
  where
    get_fields (ConDeclCtx names)
      = concatMapM (lookupConstructorFields . unLoc) names
    get_fields _
      = do { addErr (hang (text "Record syntax is illegal here:")
                                   2 (ppr ty))
           ; return [] }

rnHsTyKi env (HsFunTy _ ty1 ty2)
  = do { (ty1', fvs1) <- rnLHsTyKi env ty1
        -- Might find a for-all as the arg of a function type
       ; (ty2', fvs2) <- rnLHsTyKi env ty2
        -- Or as the result.  This happens when reading Prelude.hi
        -- when we find return :: forall m. Monad m -> forall a. a -> m a

        -- Check for fixity rearrangements
       ; res_ty <- mkHsOpTyRn (HsFunTy noExt) funTyConName funTyFixity ty1' ty2'
       ; return (res_ty, fvs1 `plusFV` fvs2) }

rnHsTyKi env listTy@(HsListTy _ ty)
  = do { data_kinds <- xoptM LangExt.DataKinds
       ; when (not data_kinds && isRnKindLevel env)
              (addErr (dataKindsErr env listTy))
       ; (ty', fvs) <- rnLHsTyKi env ty
       ; return (HsListTy noExt ty', fvs) }

rnHsTyKi env t@(HsKindSig _ ty k)
  = do { checkTypeInType env t
       ; kind_sigs_ok <- xoptM LangExt.KindSignatures
       ; unless kind_sigs_ok (badKindSigErr (rtke_ctxt env) ty)
       ; (ty', fvs1) <- rnLHsTyKi env ty
       ; (k', fvs2)  <- rnLHsTyKi (env { rtke_level = KindLevel }) k
       ; return (HsKindSig noExt ty' k', fvs1 `plusFV` fvs2) }

rnHsTyKi env t@(HsPArrTy _ ty)
  = do { notInKinds env t
       ; (ty', fvs) <- rnLHsTyKi env ty
       ; return (HsPArrTy noExt ty', fvs) }

-- Unboxed tuples are allowed to have poly-typed arguments.  These
-- sometimes crop up as a result of CPR worker-wrappering dictionaries.
rnHsTyKi env tupleTy@(HsTupleTy _ tup_con tys)
  = do { data_kinds <- xoptM LangExt.DataKinds
       ; when (not data_kinds && isRnKindLevel env)
              (addErr (dataKindsErr env tupleTy))
       ; (tys', fvs) <- mapFvRn (rnLHsTyKi env) tys
       ; return (HsTupleTy noExt tup_con tys', fvs) }

rnHsTyKi env sumTy@(HsSumTy _ tys)
  = do { data_kinds <- xoptM LangExt.DataKinds
       ; when (not data_kinds && isRnKindLevel env)
              (addErr (dataKindsErr env sumTy))
       ; (tys', fvs) <- mapFvRn (rnLHsTyKi env) tys
       ; return (HsSumTy noExt tys', fvs) }

-- Ensure that a type-level integer is nonnegative (#8306, #8412)
rnHsTyKi env tyLit@(HsTyLit _ t)
  = do { data_kinds <- xoptM LangExt.DataKinds
       ; unless data_kinds (addErr (dataKindsErr env tyLit))
       ; when (negLit t) (addErr negLitErr)
       ; checkTypeInType env tyLit
       ; return (HsTyLit noExt t, emptyFVs) }
  where
    negLit (HsStrTy _ _) = False
    negLit (HsNumTy _ i) = i < 0
    negLitErr = text "Illegal literal in type (type literals must not be negative):" <+> ppr tyLit

rnHsTyKi env overall_ty@(HsAppsTy _ tys)
  = do { -- Step 1: Break up the HsAppsTy into symbols and non-symbol regions
         let (non_syms, syms) = splitHsAppsTy tys

             -- Step 2: rename the pieces
       ; (syms1, fvs1)      <- mapFvRn (rnHsTyOp env overall_ty) syms
       ; (non_syms1, fvs2)  <- (mapFvRn . mapFvRn) (rnLHsTyKi env) non_syms

             -- Step 3: deal with *. See Note [Dealing with *]
       ; let (non_syms2, syms2) = deal_with_star [] [] non_syms1 syms1

             -- Step 4: collapse the non-symbol regions with HsAppTy
       ; non_syms3 <- mapM deal_with_non_syms non_syms2

             -- Step 5: assemble the pieces, using mkHsOpTyRn
       ; L _ res_ty <- build_res_ty non_syms3 syms2

        -- all done. Phew.
       ; return (res_ty, fvs1 `plusFV` fvs2) }
  where
    -- See Note [Dealing with *]
    deal_with_star :: [[LHsType GhcRn]] -> [Located Name]
                   -> [[LHsType GhcRn]] -> [Located Name]
                   -> ([[LHsType GhcRn]], [Located Name])
    deal_with_star acc1 acc2
                   (non_syms1 : non_syms2 : non_syms) (L loc star : ops)
      | star `hasKey` starKindTyConKey || star `hasKey` unicodeStarKindTyConKey
      = deal_with_star acc1 acc2
                   ((non_syms1 ++ L loc (HsTyVar noExt NotPromoted (L loc star))
                            : non_syms2) : non_syms)
                       ops
    deal_with_star acc1 acc2 (non_syms1 : non_syms) (op1 : ops)
      = deal_with_star (non_syms1 : acc1) (op1 : acc2) non_syms ops
    deal_with_star acc1 acc2 [non_syms] []
      = (reverse (non_syms : acc1), reverse acc2)
    deal_with_star _ _ _ _
      = pprPanic "deal_with_star" (ppr overall_ty)

    -- collapse [LHsType GhcRn] to LHsType GhcRn by making applications
    -- monadic only for failure
    deal_with_non_syms :: [LHsType GhcRn] -> RnM (LHsType GhcRn)
    deal_with_non_syms (non_sym : non_syms) = return $ mkHsAppTys non_sym non_syms
    deal_with_non_syms []                   = failWith (emptyNonSymsErr overall_ty)

    -- assemble a right-biased OpTy for use in mkHsOpTyRn
    build_res_ty :: [LHsType GhcRn] -> [Located Name] -> RnM (LHsType GhcRn)
    build_res_ty (arg1 : args) (op1 : ops)
      = do { rhs <- build_res_ty args ops
           ; fix <- lookupTyFixityRn op1
           ; res <- mkHsOpTyRn (\t1 t2 -> HsOpTy noExt t1 op1 t2) (unLoc op1)
                                                                    fix arg1 rhs
           ; let loc = combineSrcSpans (getLoc arg1) (getLoc rhs)
           ; return (L loc res)
           }
    build_res_ty [arg] [] = return arg
    build_res_ty _ _ = pprPanic "build_op_ty" (ppr overall_ty)

rnHsTyKi env (HsAppTy _ ty1 ty2)
  = do { (ty1', fvs1) <- rnLHsTyKi env ty1
       ; (ty2', fvs2) <- rnLHsTyKi env ty2
       ; return (HsAppTy noExt ty1' ty2', fvs1 `plusFV` fvs2) }

rnHsTyKi env t@(HsIParamTy _ n ty)
  = do { notInKinds env t
       ; (ty', fvs) <- rnLHsTyKi env ty
       ; return (HsIParamTy noExt n ty', fvs) }

rnHsTyKi env t@(HsEqTy _ ty1 ty2)
  = do { checkTypeInType env t
       ; (ty1', fvs1) <- rnLHsTyKi env ty1
       ; (ty2', fvs2) <- rnLHsTyKi env ty2
       ; return (HsEqTy noExt ty1' ty2', fvs1 `plusFV` fvs2) }

rnHsTyKi _ (HsSpliceTy _ sp)
  = rnSpliceType sp

rnHsTyKi env (HsDocTy _ ty haddock_doc)
  = do { (ty', fvs) <- rnLHsTyKi env ty
       ; haddock_doc' <- rnLHsDoc haddock_doc
       ; return (HsDocTy noExt ty' haddock_doc', fvs) }

rnHsTyKi _ (XHsType (NHsCoreTy ty))
  = return (XHsType (NHsCoreTy ty), emptyFVs)
    -- The emptyFVs probably isn't quite right
    -- but I don't think it matters

rnHsTyKi env ty@(HsExplicitListTy _ ip tys)
  = do { checkTypeInType env ty
       ; data_kinds <- xoptM LangExt.DataKinds
       ; unless data_kinds (addErr (dataKindsErr env ty))
       ; (tys', fvs) <- mapFvRn (rnLHsTyKi env) tys
       ; return (HsExplicitListTy noExt ip tys', fvs) }

rnHsTyKi env ty@(HsExplicitTupleTy _ tys)
  = do { checkTypeInType env ty
       ; data_kinds <- xoptM LangExt.DataKinds
       ; unless data_kinds (addErr (dataKindsErr env ty))
       ; (tys', fvs) <- mapFvRn (rnLHsTyKi env) tys
       ; return (HsExplicitTupleTy noExt tys', fvs) }

rnHsTyKi env (HsWildCardTy _)
  = do { checkAnonWildCard env
       ; wc' <- rnAnonWildCard
       ; return (HsWildCardTy wc', emptyFVs) }
         -- emptyFVs: this occurrence does not refer to a
         --           user-written binding site, so don't treat
         --           it as a free variable

--------------
rnTyVar :: RnTyKiEnv -> RdrName -> RnM Name
rnTyVar env rdr_name
  = do { name <- if   isRnKindLevel env
                 then lookupKindOccRn rdr_name
                 else lookupTypeOccRn rdr_name
       ; checkNamedWildCard env name
       ; return name }

rnLTyVar :: Located RdrName -> RnM (Located Name)
-- Called externally; does not deal with wildards
rnLTyVar (L loc rdr_name)
  = do { tyvar <- lookupTypeOccRn rdr_name
       ; return (L loc tyvar) }

--------------
rnHsTyOp :: Outputable a
         => RnTyKiEnv -> a -> Located RdrName
         -> RnM (Located Name, FreeVars)
rnHsTyOp env overall_ty (L loc op)
  = do { ops_ok <- xoptM LangExt.TypeOperators
       ; op' <- rnTyVar env op
       ; unless (ops_ok
                 || op' == starKindTyConName
                 || op' == unicodeStarKindTyConName
                 || op' `hasKey` eqTyConKey) $
           addErr (opTyErr op overall_ty)
       ; let l_op' = L loc op'
       ; return (l_op', unitFV op') }

--------------
notAllowed :: SDoc -> SDoc
notAllowed doc
  = text "Wildcard" <+> quotes doc <+> ptext (sLit "not allowed")

checkWildCard :: RnTyKiEnv -> Maybe SDoc -> RnM ()
checkWildCard env (Just doc)
  = addErr $ vcat [doc, nest 2 (text "in" <+> pprHsDocContext (rtke_ctxt env))]
checkWildCard _ Nothing
  = return ()

checkAnonWildCard :: RnTyKiEnv -> RnM ()
-- Report an error if an anonymous wildcard is illegal here
checkAnonWildCard env
  = checkWildCard env mb_bad
  where
    mb_bad :: Maybe SDoc
    mb_bad | not (wildCardsAllowed env)
           = Just (notAllowed pprAnonWildCard)
           | otherwise
           = case rtke_what env of
               RnTypeBody      -> Nothing
               RnConstraint    -> Just constraint_msg
               RnTopConstraint -> Just constraint_msg

    constraint_msg = hang
                         (notAllowed pprAnonWildCard <+> text "in a constraint")
                        2 hint_msg
    hint_msg = vcat [ text "except as the last top-level constraint of a type signature"
                    , nest 2 (text "e.g  f :: (Eq a, _) => blah") ]

checkNamedWildCard :: RnTyKiEnv -> Name -> RnM ()
-- Report an error if a named wildcard is illegal here
checkNamedWildCard env name
  = checkWildCard env mb_bad
  where
    mb_bad | not (name `elemNameSet` rtke_nwcs env)
           = Nothing  -- Not a wildcard
           | not (wildCardsAllowed env)
           = Just (notAllowed (ppr name))
           | otherwise
           = case rtke_what env of
               RnTypeBody      -> Nothing   -- Allowed
               RnTopConstraint -> Nothing   -- Allowed
               RnConstraint    -> Just constraint_msg
    constraint_msg = notAllowed (ppr name) <+> text "in a constraint"

wildCardsAllowed :: RnTyKiEnv -> Bool
-- ^ In what contexts are wildcards permitted
wildCardsAllowed env
   = case rtke_ctxt env of
       TypeSigCtx {}       -> True
       TypBrCtx {}         -> True   -- Template Haskell quoted type
       SpliceTypeCtx {}    -> True   -- Result of a Template Haskell splice
       ExprWithTySigCtx {} -> True
       PatCtx {}           -> True
       RuleCtx {}          -> True
       FamPatCtx {}        -> True   -- Not named wildcards though
       GHCiCtx {}          -> True
       HsTypeCtx {}        -> True
       _                   -> False

rnAnonWildCard :: RnM (HsWildCardInfo GhcRn)
rnAnonWildCard
  = do { loc <- getSrcSpanM
       ; uniq <- newUnique
       ; let name = mkInternalName uniq (mkTyVarOcc "_") loc
       ; return (AnonWildCard (L loc name)) }

---------------
-- | Ensures either that we're in a type or that -XTypeInType is set
checkTypeInType :: Outputable ty
                => RnTyKiEnv
                -> ty      -- ^ type
                -> RnM ()
checkTypeInType env ty
  | isRnKindLevel env
  = do { type_in_type <- xoptM LangExt.TypeInType
       ; unless type_in_type $
         addErr (text "Illegal kind:" <+> ppr ty $$
                 text "Did you mean to enable TypeInType?") }
checkTypeInType _ _ = return ()

notInKinds :: Outputable ty
           => RnTyKiEnv
           -> ty
           -> RnM ()
notInKinds env ty
  | isRnKindLevel env
  = addErr (text "Illegal kind (even with TypeInType enabled):" <+> ppr ty)
notInKinds _ _ = return ()

{- *****************************************************
*                                                      *
          Binding type variables
*                                                      *
***************************************************** -}

bindSigTyVarsFV :: [Name]
                -> RnM (a, FreeVars)
                -> RnM (a, FreeVars)
-- Used just before renaming the defn of a function
-- with a separate type signature, to bring its tyvars into scope
-- With no -XScopedTypeVariables, this is a no-op
bindSigTyVarsFV tvs thing_inside
  = do  { scoped_tyvars <- xoptM LangExt.ScopedTypeVariables
        ; if not scoped_tyvars then
                thing_inside
          else
                bindLocalNamesFV tvs thing_inside }

-- | Simply bring a bunch of RdrNames into scope. No checking for
-- validity, at all. The binding location is taken from the location
-- on each name.
bindLRdrNames :: [Located RdrName]
              -> ([Name] -> RnM (a, FreeVars))
              -> RnM (a, FreeVars)
bindLRdrNames rdrs thing_inside
  = do { var_names <- mapM (newTyVarNameRn Nothing) rdrs
       ; bindLocalNamesFV var_names $
         thing_inside var_names }

---------------
bindHsQTyVars :: forall a b.
                 HsDocContext
              -> Maybe SDoc         -- Just d => check for unused tvs
                                    --   d is a phrase like "in the type ..."
              -> Maybe a            -- Just _  => an associated type decl
              -> [Located RdrName]  -- Kind variables from scope, no dups
              -> (LHsQTyVars GhcPs)
              -> (LHsQTyVars GhcRn -> Bool -> RnM (b, FreeVars))
                  -- The Bool is True <=> all kind variables used in the
                  -- kind signature are bound on the left.  Reason:
                  -- the TypeInType clause of Note [Complete user-supplied
                  -- kind signatures] in HsDecls
              -> RnM (b, FreeVars)

-- See Note [bindHsQTyVars examples]
-- (a) Bring kind variables into scope
--     both (i)  passed in body_kv_occs
--     and  (ii) mentioned in the kinds of hsq_bndrs
-- (b) Bring type variables into scope
--
bindHsQTyVars doc mb_in_doc mb_assoc body_kv_occs hsq_bndrs thing_inside
  = do { let hs_tv_bndrs = hsQTvExplicit hsq_bndrs
       ; bndr_kv_occs <- extractHsTyVarBndrsKVs hs_tv_bndrs
       ; rdr_env <- getLocalRdrEnv

       ; let -- See Note [bindHsQTyVars examples] for what
             -- all these various things are doing
             bndrs, kv_occs, implicit_kvs :: [Located RdrName]
             bndrs        = map hsLTyVarLocName hs_tv_bndrs
             kv_occs      = nubL (body_kv_occs ++ bndr_kv_occs)
             implicit_kvs = filter_occs rdr_env bndrs kv_occs
                                 -- Deleting bndrs: See Note [Kind-variable ordering]
             -- dep_bndrs is the subset of bndrs that are dependent
             --   i.e. appear in bndr/body_kv_occs
             -- Can't use implicit_kvs because we've deleted bndrs from that!
             dep_bndrs = filter (`elemRdr` kv_occs) bndrs
             del       = deleteBys eqLocated
             all_bound_on_lhs = null ((body_kv_occs `del` bndrs) `del` bndr_kv_occs)

       ; traceRn "checkMixedVars3" $
           vcat [ text "kv_occs" <+> ppr kv_occs
                , text "bndrs"   <+> ppr hs_tv_bndrs
                , text "bndr_kv_occs"   <+> ppr bndr_kv_occs
                , text "wubble" <+> ppr ((kv_occs \\ bndrs) \\ bndr_kv_occs)
                ]
       ; checkBadKindBndrs doc implicit_kvs
       ; checkMixedVars kv_occs bndrs

       ; implicit_kv_nms <- mapM (newTyVarNameRn mb_assoc) implicit_kvs

       ; bindLocalNamesFV implicit_kv_nms                     $
         bindLHsTyVarBndrs doc mb_in_doc mb_assoc hs_tv_bndrs $ \ rn_bndrs ->
    do { traceRn "bindHsQTyVars" (ppr hsq_bndrs $$ ppr implicit_kv_nms $$ ppr rn_bndrs)
       ; dep_bndr_nms <- mapM (lookupLocalOccRn . unLoc) dep_bndrs
       ; thing_inside (HsQTvs { hsq_implicit  = implicit_kv_nms
                              , hsq_explicit  = rn_bndrs
                              , hsq_dependent = mkNameSet dep_bndr_nms })
                      all_bound_on_lhs } }

  where
    filter_occs :: LocalRdrEnv         -- In scope
                -> [Located RdrName]   -- Bound here
                -> [Located RdrName]   -- Potential implicit binders
                -> [Located RdrName]   -- Final implicit binders
    -- Filter out any potential implicit binders that are either
    -- already in scope, or are explicitly bound here
    filter_occs rdr_env bndrs occs
      = filterOut is_in_scope occs
      where
        is_in_scope locc@(L _ occ) = isJust (lookupLocalRdrEnv rdr_env occ)
                                  || locc `elemRdr` bndrs

{- Note [bindHsQTyVars examples]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we have
   data T k (a::k1) (b::k) :: k2 -> k1 -> *

Then:
  hs_tv_bndrs = [k, a::k1, b::k], the explicitly-bound variables
  bndrs       = [k,a,b]

  bndr_kv_occs = [k,k1], kind variables free in kind signatures
                         of hs_tv_bndrs

  body_kv_occs = [k2,k1], kind variables free in the
                          result kind signature

  implicit_kvs = [k1,k2], kind variables free in kind signatures
                          of hs_tv_bndrs, and not bound by bndrs

* We want to quantify add implicit bindings for implicit_kvs

* The "dependent" bndrs (hsq_dependent) are the subset of
  bndrs that are free in bndr_kv_occs or body_kv_occs

* If implicit_body_kvs is non-empty, then there is a kind variable
  mentioned in the kind signature that is not bound "on the left".
  That's one of the rules for a CUSK, so we pass that info on
  as the second argument to thing_inside.

* Order is not important in these lists.  All we are doing is
  bring Names into scope.

Finally, you may wonder why filter_occs removes in-scope variables
from bndr/body_kv_occs.  How can anything be in scope?  Answer:
HsQTyVars is /also/ used (slightly oddly) for Haskell-98 syntax
ConDecls
   data T a = forall (b::k). MkT a b
The ConDecl has a LHsQTyVars in it; but 'a' scopes over the entire
ConDecl.  Hence the local RdrEnv may be non-empty and we must filter
out 'a' from the free vars.  (Mind you, in this situation all the
implicit kind variables are bound at the data type level, so there
are none to bind in the ConDecl, so there are no implicitly bound
variables at all.

Note [Kind variable scoping]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we have
  data T (a :: k) k = ...
we report "k is out of scope" for (a::k).  Reason: k is not brought
into scope until the explicit k-binding that follows.  It would be
terribly confusing to bring into scope an /implicit/ k for a's kind
and a distinct, shadowing explicit k that follows, something like
  data T {k1} (a :: k1) k = ...

So the rule is:

   the implicit binders never include any
   of the explicit binders in the group

Note that in the denerate case
  data T (a :: a) = blah
we get a complaint the second 'a' is not in scope.

That applies to foralls too: e.g.
   forall (a :: k) k . blah

But if the foralls are split, we treat the two groups separately:
   forall (a :: k). forall k. blah
Here we bring into scope an implicit k, which is later shadowed
by the explicit k.

In implementation terms

* In bindHsQTyVars 'k' is free in bndr_kv_occs; then we delete
  the binders {a,k}, and so end with no implicit binders.  Then we
  rename the binders left-to-right, and hence see that 'k' is out of
  scope in the kind of 'a'.

* Similarly in extract_hs_tv_bndrs
-}

bindLHsTyVarBndrs :: HsDocContext
                  -> Maybe SDoc            -- Just d => check for unused tvs
                                           --   d is a phrase like "in the type ..."
                  -> Maybe a               -- Just _  => an associated type decl
                  -> [LHsTyVarBndr GhcPs]  -- User-written tyvars
                  -> ([LHsTyVarBndr GhcRn] -> RnM (b, FreeVars))
                  -> RnM (b, FreeVars)
bindLHsTyVarBndrs doc mb_in_doc mb_assoc tv_bndrs thing_inside
  = do { when (isNothing mb_assoc) (checkShadowedRdrNames tv_names_w_loc)
       ; checkDupRdrNames tv_names_w_loc
       ; go tv_bndrs thing_inside }
  where
    tv_names_w_loc = map hsLTyVarLocName tv_bndrs

    go []     thing_inside = thing_inside []
    go (b:bs) thing_inside = bindLHsTyVarBndr doc mb_assoc b $ \ b' ->
                             do { (res, fvs) <- go bs $ \ bs' ->
                                                thing_inside (b' : bs')
                                ; warn_unused b' fvs
                                ; return (res, fvs) }

    warn_unused tv_bndr fvs = case mb_in_doc of
      Just in_doc -> warnUnusedForAll in_doc tv_bndr fvs
      Nothing     -> return ()

bindLHsTyVarBndr :: HsDocContext
                 -> Maybe a   -- associated class
                 -> LHsTyVarBndr GhcPs
                 -> (LHsTyVarBndr GhcRn -> RnM (b, FreeVars))
                 -> RnM (b, FreeVars)
bindLHsTyVarBndr _doc mb_assoc (L loc (UserTyVar x lrdr@(L lv _))) thing_inside
  = do { nm <- newTyVarNameRn mb_assoc lrdr
       ; bindLocalNamesFV [nm] $
         thing_inside (L loc (UserTyVar x (L lv nm))) }

bindLHsTyVarBndr doc mb_assoc (L loc (KindedTyVar x lrdr@(L lv _) kind))
                 thing_inside
  = do { sig_ok <- xoptM LangExt.KindSignatures
           ; unless sig_ok (badKindSigErr doc kind)
           ; (kind', fvs1) <- rnLHsKind doc kind
           ; tv_nm  <- newTyVarNameRn mb_assoc lrdr
           ; (b, fvs2) <- bindLocalNamesFV [tv_nm] $
                         thing_inside (L loc (KindedTyVar x (L lv tv_nm) kind'))
           ; return (b, fvs1 `plusFV` fvs2) }

bindLHsTyVarBndr _ _ (L _ (XTyVarBndr{})) _ = panic "bindLHsTyVarBndr"

newTyVarNameRn :: Maybe a -> Located RdrName -> RnM Name
newTyVarNameRn mb_assoc (L loc rdr)
  = do { rdr_env <- getLocalRdrEnv
       ; case (mb_assoc, lookupLocalRdrEnv rdr_env rdr) of
           (Just _, Just n) -> return n
              -- Use the same Name as the parent class decl

           _                -> newLocalBndrRn (L loc rdr) }

---------------------
collectAnonWildCards :: LHsType GhcRn -> [Name]
-- | Extract all wild cards from a type.
collectAnonWildCards lty = go lty
  where
    go (L _ ty) = case ty of
      HsWildCardTy (AnonWildCard (L _ wc)) -> [wc]
      HsAppsTy _ tys           -> gos (mapMaybe (prefix_types_only . unLoc) tys)
      HsAppTy _ ty1 ty2              -> go ty1 `mappend` go ty2
      HsFunTy _ ty1 ty2              -> go ty1 `mappend` go ty2
      HsListTy _ ty                  -> go ty
      HsPArrTy _ ty                  -> go ty
      HsTupleTy _ _ tys              -> gos tys
      HsSumTy _ tys                  -> gos tys
      HsOpTy _ ty1 _ ty2             -> go ty1 `mappend` go ty2
      HsParTy _ ty                   -> go ty
      HsIParamTy _ _ ty              -> go ty
      HsEqTy _ ty1 ty2               -> go ty1 `mappend` go ty2
      HsKindSig _ ty kind            -> go ty `mappend` go kind
      HsDocTy _ ty _                 -> go ty
      HsBangTy _ _ ty                -> go ty
      HsRecTy _ flds                 -> gos $ map (cd_fld_type . unLoc) flds
      HsExplicitListTy _ _ tys       -> gos tys
      HsExplicitTupleTy _ tys        -> gos tys
      HsForAllTy { hst_bndrs = bndrs
                 , hst_body = ty } -> collectAnonWildCardsBndrs bndrs
                                      `mappend` go ty
      HsQualTy { hst_ctxt = L _ ctxt
               , hst_body = ty }  -> gos ctxt `mappend` go ty
      HsSpliceTy _ (HsSpliced _ (HsSplicedTy ty)) -> go $ L noSrcSpan ty
      HsSpliceTy{} -> mempty
      HsTyLit{} -> mempty
      HsTyVar{} -> mempty
      XHsType{} -> mempty

    gos = mconcat . map go

    prefix_types_only (HsAppPrefix _ ty) = Just ty
    prefix_types_only (HsAppInfix _ _)   = Nothing
    prefix_types_only (XAppType _)       = Nothing

collectAnonWildCardsBndrs :: [LHsTyVarBndr GhcRn] -> [Name]
collectAnonWildCardsBndrs ltvs = concatMap (go . unLoc) ltvs
  where
    go (UserTyVar _ _)      = []
    go (KindedTyVar _ _ ki) = collectAnonWildCards ki
    go (XTyVarBndr{})       = []

{-
*********************************************************
*                                                       *
        ConDeclField
*                                                       *
*********************************************************

When renaming a ConDeclField, we have to find the FieldLabel
associated with each field.  But we already have all the FieldLabels
available (since they were brought into scope by
RnNames.getLocalNonValBinders), so we just take the list as an
argument, build a map and look them up.
-}

rnConDeclFields :: HsDocContext -> [FieldLabel] -> [LConDeclField GhcPs]
                -> RnM ([LConDeclField GhcRn], FreeVars)
-- Also called from RnSource
-- No wildcards can appear in record fields
rnConDeclFields ctxt fls fields
   = mapFvRn (rnField fl_env env) fields
  where
    env    = mkTyKiEnv ctxt TypeLevel RnTypeBody
    fl_env = mkFsEnv [ (flLabel fl, fl) | fl <- fls ]

rnField :: FastStringEnv FieldLabel -> RnTyKiEnv -> LConDeclField GhcPs
        -> RnM (LConDeclField GhcRn, FreeVars)
rnField fl_env env (L l (ConDeclField names ty haddock_doc))
  = do { let new_names = map (fmap lookupField) names
       ; (new_ty, fvs) <- rnLHsTyKi env ty
       ; new_haddock_doc <- rnMbLHsDoc haddock_doc
       ; return (L l (ConDeclField new_names new_ty new_haddock_doc), fvs) }
  where
    lookupField :: FieldOcc GhcPs -> FieldOcc GhcRn
    lookupField (FieldOcc _ (L lr rdr)) = FieldOcc (flSelector fl) (L lr rdr)
      where
        lbl = occNameFS $ rdrNameOcc rdr
        fl  = expectJust "rnField" $ lookupFsEnv fl_env lbl
    lookupField (XFieldOcc{}) = panic "rnField"

{-
************************************************************************
*                                                                      *
        Fixities and precedence parsing
*                                                                      *
************************************************************************

@mkOpAppRn@ deals with operator fixities.  The argument expressions
are assumed to be already correctly arranged.  It needs the fixities
recorded in the OpApp nodes, because fixity info applies to the things
the programmer actually wrote, so you can't find it out from the Name.

Furthermore, the second argument is guaranteed not to be another
operator application.  Why? Because the parser parses all
operator applications left-associatively, EXCEPT negation, which
we need to handle specially.
Infix types are read in a *right-associative* way, so that
        a `op` b `op` c
is always read in as
        a `op` (b `op` c)

mkHsOpTyRn rearranges where necessary.  The two arguments
have already been renamed and rearranged.  It's made rather tiresome
by the presence of ->, which is a separate syntactic construct.
-}

---------------
-- Building (ty1 `op1` (ty21 `op2` ty22))
mkHsOpTyRn :: (LHsType GhcRn -> LHsType GhcRn -> HsType GhcRn)
           -> Name -> Fixity -> LHsType GhcRn -> LHsType GhcRn
           -> RnM (HsType GhcRn)

mkHsOpTyRn mk1 pp_op1 fix1 ty1 (L loc2 (HsOpTy noExt ty21 op2 ty22))
  = do  { fix2 <- lookupTyFixityRn op2
        ; mk_hs_op_ty mk1 pp_op1 fix1 ty1
                      (\t1 t2 -> HsOpTy noExt t1 op2 t2)
                      (unLoc op2) fix2 ty21 ty22 loc2 }

mkHsOpTyRn mk1 pp_op1 fix1 ty1 (L loc2 (HsFunTy _ ty21 ty22))
  = mk_hs_op_ty mk1 pp_op1 fix1 ty1
                (HsFunTy noExt) funTyConName funTyFixity ty21 ty22 loc2

mkHsOpTyRn mk1 _ _ ty1 ty2              -- Default case, no rearrangment
  = return (mk1 ty1 ty2)

---------------
mk_hs_op_ty :: (LHsType GhcRn -> LHsType GhcRn -> HsType GhcRn)
            -> Name -> Fixity -> LHsType GhcRn
            -> (LHsType GhcRn -> LHsType GhcRn -> HsType GhcRn)
            -> Name -> Fixity -> LHsType GhcRn -> LHsType GhcRn -> SrcSpan
            -> RnM (HsType GhcRn)
mk_hs_op_ty mk1 op1 fix1 ty1
            mk2 op2 fix2 ty21 ty22 loc2
  | nofix_error     = do { precParseErr (NormalOp op1,fix1) (NormalOp op2,fix2)
                         ; return (mk1 ty1 (L loc2 (mk2 ty21 ty22))) }
  | associate_right = return (mk1 ty1 (L loc2 (mk2 ty21 ty22)))
  | otherwise       = do { -- Rearrange to ((ty1 `op1` ty21) `op2` ty22)
                           new_ty <- mkHsOpTyRn mk1 op1 fix1 ty1 ty21
                         ; return (mk2 (noLoc new_ty) ty22) }
  where
    (nofix_error, associate_right) = compareFixity fix1 fix2


---------------------------
mkOpAppRn :: LHsExpr GhcRn             -- Left operand; already rearranged
          -> LHsExpr GhcRn -> Fixity   -- Operator and fixity
          -> LHsExpr GhcRn             -- Right operand (not an OpApp, but might
                                       -- be a NegApp)
          -> RnM (HsExpr GhcRn)

-- (e11 `op1` e12) `op2` e2
mkOpAppRn e1@(L _ (OpApp fix1 e11 op1 e12)) op2 fix2 e2
  | nofix_error
  = do precParseErr (get_op op1,fix1) (get_op op2,fix2)
       return (OpApp fix2 e1 op2 e2)

  | associate_right = do
    new_e <- mkOpAppRn e12 op2 fix2 e2
    return (OpApp fix1 e11 op1 (L loc' new_e))
  where
    loc'= combineLocs e12 e2
    (nofix_error, associate_right) = compareFixity fix1 fix2

---------------------------
--      (- neg_arg) `op` e2
mkOpAppRn e1@(L _ (NegApp _ neg_arg neg_name)) op2 fix2 e2
  | nofix_error
  = do precParseErr (NegateOp,negateFixity) (get_op op2,fix2)
       return (OpApp fix2 e1 op2 e2)

  | associate_right
  = do new_e <- mkOpAppRn neg_arg op2 fix2 e2
       return (NegApp noExt (L loc' new_e) neg_name)
  where
    loc' = combineLocs neg_arg e2
    (nofix_error, associate_right) = compareFixity negateFixity fix2

---------------------------
--      e1 `op` - neg_arg
mkOpAppRn e1 op1 fix1 e2@(L _ (NegApp {}))     -- NegApp can occur on the right
  | not associate_right                 -- We *want* right association
  = do precParseErr (get_op op1, fix1) (NegateOp, negateFixity)
       return (OpApp fix1 e1 op1 e2)
  where
    (_, associate_right) = compareFixity fix1 negateFixity

---------------------------
--      Default case
mkOpAppRn e1 op fix e2                  -- Default case, no rearrangment
  = ASSERT2( right_op_ok fix (unLoc e2),
             ppr e1 $$ text "---" $$ ppr op $$ text "---" $$ ppr fix $$ text "---" $$ ppr e2
    )
    return (OpApp fix e1 op e2)

----------------------------

-- | Name of an operator in an operator application or section
data OpName = NormalOp Name         -- ^ A normal identifier
            | NegateOp              -- ^ Prefix negation
            | UnboundOp UnboundVar  -- ^ An unbound indentifier
            | RecFldOp (AmbiguousFieldOcc GhcRn)
              -- ^ A (possibly ambiguous) record field occurrence

instance Outputable OpName where
  ppr (NormalOp n)   = ppr n
  ppr NegateOp       = ppr negateName
  ppr (UnboundOp uv) = ppr uv
  ppr (RecFldOp fld) = ppr fld

get_op :: LHsExpr GhcRn -> OpName
-- An unbound name could be either HsVar or HsUnboundVar
-- See RnExpr.rnUnboundVar
get_op (L _ (HsVar _ (L _ n)))   = NormalOp n
get_op (L _ (HsUnboundVar _ uv)) = UnboundOp uv
get_op (L _ (HsRecFld _ fld))    = RecFldOp fld
get_op other                     = pprPanic "get_op" (ppr other)

-- Parser left-associates everything, but
-- derived instances may have correctly-associated things to
-- in the right operand.  So we just check that the right operand is OK
right_op_ok :: Fixity -> HsExpr GhcRn -> Bool
right_op_ok fix1 (OpApp fix2 _ _ _)
  = not error_please && associate_right
  where
    (error_please, associate_right) = compareFixity fix1 fix2
right_op_ok _ _
  = True

-- Parser initially makes negation bind more tightly than any other operator
-- And "deriving" code should respect this (use HsPar if not)
mkNegAppRn :: LHsExpr (GhcPass id) -> SyntaxExpr (GhcPass id)
           -> RnM (HsExpr (GhcPass id))
mkNegAppRn neg_arg neg_name
  = ASSERT( not_op_app (unLoc neg_arg) )
    return (NegApp noExt neg_arg neg_name)

not_op_app :: HsExpr id -> Bool
not_op_app (OpApp {}) = False
not_op_app _          = True

---------------------------
mkOpFormRn :: LHsCmdTop GhcRn            -- Left operand; already rearranged
          -> LHsExpr GhcRn -> Fixity     -- Operator and fixity
          -> LHsCmdTop GhcRn             -- Right operand (not an infix)
          -> RnM (HsCmd GhcRn)

-- (e11 `op1` e12) `op2` e2
mkOpFormRn a1@(L loc (HsCmdTop (L _ (HsCmdArrForm op1 f (Just fix1)
                                     [a11,a12])) _ _ _))
        op2 fix2 a2
  | nofix_error
  = do precParseErr (get_op op1,fix1) (get_op op2,fix2)
       return (HsCmdArrForm op2 f (Just fix2) [a1, a2])

  | associate_right
  = do new_c <- mkOpFormRn a12 op2 fix2 a2
       return (HsCmdArrForm op1 f (Just fix1)
               [a11, L loc (HsCmdTop (L loc new_c)
               placeHolderType placeHolderType [])])
        -- TODO: locs are wrong
  where
    (nofix_error, associate_right) = compareFixity fix1 fix2

--      Default case
mkOpFormRn arg1 op fix arg2                     -- Default case, no rearrangment
  = return (HsCmdArrForm op Infix (Just fix) [arg1, arg2])


--------------------------------------
mkConOpPatRn :: Located Name -> Fixity -> LPat GhcRn -> LPat GhcRn
             -> RnM (Pat GhcRn)

mkConOpPatRn op2 fix2 p1@(L loc (ConPatIn op1 (InfixCon p11 p12))) p2
  = do  { fix1 <- lookupFixityRn (unLoc op1)
        ; let (nofix_error, associate_right) = compareFixity fix1 fix2

        ; if nofix_error then do
                { precParseErr (NormalOp (unLoc op1),fix1)
                               (NormalOp (unLoc op2),fix2)
                ; return (ConPatIn op2 (InfixCon p1 p2)) }

          else if associate_right then do
                { new_p <- mkConOpPatRn op2 fix2 p12 p2
                ; return (ConPatIn op1 (InfixCon p11 (L loc new_p))) } -- XXX loc right?
          else return (ConPatIn op2 (InfixCon p1 p2)) }

mkConOpPatRn op _ p1 p2                         -- Default case, no rearrangment
  = ASSERT( not_op_pat (unLoc p2) )
    return (ConPatIn op (InfixCon p1 p2))

not_op_pat :: Pat GhcRn -> Bool
not_op_pat (ConPatIn _ (InfixCon _ _)) = False
not_op_pat _                           = True

--------------------------------------
checkPrecMatch :: Name -> MatchGroup GhcRn body -> RnM ()
  -- Check precedence of a function binding written infix
  --   eg  a `op` b `C` c = ...
  -- See comments with rnExpr (OpApp ...) about "deriving"

checkPrecMatch op (MG { mg_alts = L _ ms })
  = mapM_ check ms
  where
    check (L _ (Match { m_pats = L l1 p1 : L l2 p2 :_ }))
      = setSrcSpan (combineSrcSpans l1 l2) $
        do checkPrec op p1 False
           checkPrec op p2 True

    check _ = return ()
        -- This can happen.  Consider
        --      a `op` True = ...
        --      op          = ...
        -- The infix flag comes from the first binding of the group
        -- but the second eqn has no args (an error, but not discovered
        -- until the type checker).  So we don't want to crash on the
        -- second eqn.

checkPrec :: Name -> Pat GhcRn -> Bool -> IOEnv (Env TcGblEnv TcLclEnv) ()
checkPrec op (ConPatIn op1 (InfixCon _ _)) right = do
    op_fix@(Fixity _ op_prec  op_dir) <- lookupFixityRn op
    op1_fix@(Fixity _ op1_prec op1_dir) <- lookupFixityRn (unLoc op1)
    let
        inf_ok = op1_prec > op_prec ||
                 (op1_prec == op_prec &&
                  (op1_dir == InfixR && op_dir == InfixR && right ||
                   op1_dir == InfixL && op_dir == InfixL && not right))

        info  = (NormalOp op,          op_fix)
        info1 = (NormalOp (unLoc op1), op1_fix)
        (infol, infor) = if right then (info, info1) else (info1, info)
    unless inf_ok (precParseErr infol infor)

checkPrec _ _ _
  = return ()

-- Check precedence of (arg op) or (op arg) respectively
-- If arg is itself an operator application, then either
--   (a) its precedence must be higher than that of op
--   (b) its precedency & associativity must be the same as that of op
checkSectionPrec :: FixityDirection -> HsExpr GhcPs
        -> LHsExpr GhcRn -> LHsExpr GhcRn -> RnM ()
checkSectionPrec direction section op arg
  = case unLoc arg of
        OpApp fix _ op' _ -> go_for_it (get_op op') fix
        NegApp _ _ _      -> go_for_it NegateOp     negateFixity
        _                 -> return ()
  where
    op_name = get_op op
    go_for_it arg_op arg_fix@(Fixity _ arg_prec assoc) = do
          op_fix@(Fixity _ op_prec _) <- lookupFixityOp op_name
          unless (op_prec < arg_prec
                  || (op_prec == arg_prec && direction == assoc))
                 (sectionPrecErr (get_op op, op_fix)
                                 (arg_op, arg_fix) section)

-- | Look up the fixity for an operator name.  Be careful to use
-- 'lookupFieldFixityRn' for (possibly ambiguous) record fields
-- (see Trac #13132).
lookupFixityOp :: OpName -> RnM Fixity
lookupFixityOp (NormalOp n)  = lookupFixityRn n
lookupFixityOp NegateOp      = lookupFixityRn negateName
lookupFixityOp (UnboundOp u) = lookupFixityRn (mkUnboundName (unboundVarOcc u))
lookupFixityOp (RecFldOp f)  = lookupFieldFixityRn f


-- Precedence-related error messages

precParseErr :: (OpName,Fixity) -> (OpName,Fixity) -> RnM ()
precParseErr op1@(n1,_) op2@(n2,_)
  | is_unbound n1 || is_unbound n2
  = return ()     -- Avoid error cascade
  | otherwise
  = addErr $ hang (text "Precedence parsing error")
      4 (hsep [text "cannot mix", ppr_opfix op1, ptext (sLit "and"),
               ppr_opfix op2,
               text "in the same infix expression"])

sectionPrecErr :: (OpName,Fixity) -> (OpName,Fixity) -> HsExpr GhcPs -> RnM ()
sectionPrecErr op@(n1,_) arg_op@(n2,_) section
  | is_unbound n1 || is_unbound n2
  = return ()     -- Avoid error cascade
  | otherwise
  = addErr $ vcat [text "The operator" <+> ppr_opfix op <+> ptext (sLit "of a section"),
         nest 4 (sep [text "must have lower precedence than that of the operand,",
                      nest 2 (text "namely" <+> ppr_opfix arg_op)]),
         nest 4 (text "in the section:" <+> quotes (ppr section))]

is_unbound :: OpName -> Bool
is_unbound (NormalOp n) = isUnboundName n
is_unbound UnboundOp{}  = True
is_unbound _            = False

ppr_opfix :: (OpName, Fixity) -> SDoc
ppr_opfix (op, fixity) = pp_op <+> brackets (ppr fixity)
   where
     pp_op | NegateOp <- op = text "prefix `-'"
           | otherwise      = quotes (ppr op)


{- *****************************************************
*                                                      *
                 Errors
*                                                      *
***************************************************** -}

unexpectedTypeSigErr :: LHsSigWcType GhcPs -> SDoc
unexpectedTypeSigErr ty
  = hang (text "Illegal type signature:" <+> quotes (ppr ty))
       2 (text "Type signatures are only allowed in patterns with ScopedTypeVariables")

checkBadKindBndrs :: HsDocContext -> [Located RdrName] -> RnM ()
checkBadKindBndrs doc kvs
  = unless (null kvs)             $
    unlessXOptM LangExt.PolyKinds $
    addErr (withHsDocContext doc  $
            hang (text "Unexpected kind variable" <> plural kvs
                  <+> pprQuotedList kvs)
               2 (text "Perhaps you intended to use PolyKinds"))

badKindSigErr :: HsDocContext -> LHsType GhcPs -> TcM ()
badKindSigErr doc (L loc ty)
  = setSrcSpan loc $ addErr $
    withHsDocContext doc $
    hang (text "Illegal kind signature:" <+> quotes (ppr ty))
       2 (text "Perhaps you intended to use KindSignatures")

dataKindsErr :: RnTyKiEnv -> HsType GhcPs -> SDoc
dataKindsErr env thing
  = hang (text "Illegal" <+> pp_what <> colon <+> quotes (ppr thing))
       2 (text "Perhaps you intended to use DataKinds")
  where
    pp_what | isRnKindLevel env = text "kind"
            | otherwise          = text "type"

inTypeDoc :: HsType GhcPs -> SDoc
inTypeDoc ty = text "In the type" <+> quotes (ppr ty)

warnUnusedForAll :: SDoc -> LHsTyVarBndr GhcRn -> FreeVars -> TcM ()
warnUnusedForAll in_doc (L loc tv) used_names
  = whenWOptM Opt_WarnUnusedForalls $
    unless (hsTyVarName tv `elemNameSet` used_names) $
    addWarnAt (Reason Opt_WarnUnusedForalls) loc $
    vcat [ text "Unused quantified type variable" <+> quotes (ppr tv)
         , in_doc ]

opTyErr :: Outputable a => RdrName -> a -> SDoc
opTyErr op overall_ty
  = hang (text "Illegal operator" <+> quotes (ppr op) <+> ptext (sLit "in type") <+> quotes (ppr overall_ty))
         2 extra
  where
    extra | op == dot_tv_RDR
          = perhapsForallMsg
          | otherwise
          = text "Use TypeOperators to allow operators in types"

emptyNonSymsErr :: HsType GhcPs -> SDoc
emptyNonSymsErr overall_ty
  = text "Operator applied to too few arguments:" <+> ppr overall_ty

{-
************************************************************************
*                                                                      *
      Finding the free type variables of a (HsType RdrName)
*                                                                      *
************************************************************************


Note [Kind and type-variable binders]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In a type signature we may implicitly bind type variable and, more
recently, kind variables.  For example:
  *   f :: a -> a
      f = ...
    Here we need to find the free type variables of (a -> a),
    so that we know what to quantify

  *   class C (a :: k) where ...
    This binds 'k' in ..., as well as 'a'

  *   f (x :: a -> [a]) = ....
    Here we bind 'a' in ....

  *   f (x :: T a -> T (b :: k)) = ...
    Here we bind both 'a' and the kind variable 'k'

  *   type instance F (T (a :: Maybe k)) = ...a...k...
    Here we want to constrain the kind of 'a', and bind 'k'.

In general we want to walk over a type, and find
  * Its free type variables
  * The free kind variables of any kind signatures in the type

Hence we return a pair (kind-vars, type vars)
See also Note [HsBSig binder lists] in HsTypes

Most clients of this code just want to know the kind/type vars, without
duplicates. The function rmDupsInRdrTyVars removes duplicates. That function
also makes sure that no variable is reported as both a kind var and
a type var, preferring kind vars. Why kind vars? Consider this:

 foo :: forall (a :: k). Proxy k -> Proxy a -> ...

Should that be accepted?

Normally, if a type signature has an explicit forall, it must list *all*
tyvars mentioned in the type. But there's an exception for tyvars mentioned in
a kind, as k is above. Note that k is also used "as a type variable", as the
argument to the first Proxy. So, do we consider k to be type-variable-like and
require it in the forall? Or do we consider k to be kind-variable-like and not
require it?

It's not just in type signatures: kind variables are implicitly brought into
scope in a variety of places. Should vars used at both the type level and kind
level be treated this way?

GHC indeed allows kind variables to be brought into scope implicitly even when
the kind variable is also used as a type variable. Thus, we must prefer to keep
a variable listed as a kind var in rmDupsInRdrTyVars. If we kept it as a type
var, then this would prevent it from being implicitly quantified (see
rnImplicitBndrs). In the `foo` example above, that would have the consequence
of the k in Proxy k being reported as out of scope.

-}

-- See Note [Kind and type-variable binders]
data FreeKiTyVars = FKTV { fktv_kis    :: [Located RdrName]
                         , fktv_tys    :: [Located RdrName] }

-- | A 'FreeKiTyVars' list that is allowed to have duplicate variables.
type FreeKiTyVarsWithDups = FreeKiTyVars

-- | A 'FreeKiTyVars' list that contains no duplicate variables.
type FreeKiTyVarsNoDups   = FreeKiTyVars

instance Outputable FreeKiTyVars where
  ppr (FKTV kis tys) = ppr (kis, tys)

emptyFKTV :: FreeKiTyVarsNoDups
emptyFKTV = FKTV [] []

freeKiTyVarsAllVars :: FreeKiTyVars -> [Located RdrName]
freeKiTyVarsAllVars (FKTV tys kvs) = tys ++ kvs

freeKiTyVarsKindVars :: FreeKiTyVars -> [Located RdrName]
freeKiTyVarsKindVars = fktv_kis

freeKiTyVarsTypeVars :: FreeKiTyVars -> [Located RdrName]
freeKiTyVarsTypeVars = fktv_tys

filterInScope :: LocalRdrEnv -> FreeKiTyVars -> FreeKiTyVars
filterInScope rdr_env (FKTV kis tys)
  = FKTV (filterOut in_scope kis)
         (filterOut in_scope tys)
  where
    in_scope         = inScope rdr_env . unLoc

inScope :: LocalRdrEnv -> RdrName -> Bool
inScope rdr_env rdr = rdr `elemLocalRdrEnv` rdr_env

-- | 'extractHsTyRdrTyVars' finds the
--        free (kind, type) variables of an 'HsType'
-- or the free (sort, kind) variables of an 'HsKind'.
-- It's used when making the @forall@s explicit.
-- Does not return any wildcards.
-- When the same name occurs multiple times in the types, only the first
-- occurrence is returned.
-- See Note [Kind and type-variable binders]
extractHsTyRdrTyVars :: LHsType GhcPs -> RnM FreeKiTyVarsNoDups
extractHsTyRdrTyVars ty
  = rmDupsInRdrTyVars <$> extractHsTyRdrTyVarsDups ty

-- | 'extractHsTyRdrTyVarsDups' find the
--        free (kind, type) variables of an 'HsType'
-- or the free (sort, kind) variables of an 'HsKind'.
-- It's used when making the @forall@s explicit.
-- Does not return any wildcards.
-- When the same name occurs multiple times in the types, all occurrences
-- are returned.
extractHsTyRdrTyVarsDups :: LHsType GhcPs -> RnM FreeKiTyVarsWithDups
extractHsTyRdrTyVarsDups ty
  = extract_lty TypeLevel ty emptyFKTV

-- | Extracts the free kind variables (but not the type variables) of an
-- 'HsType'. Does not return any wildcards.
-- When the same name occurs multiple times in the type, only the first
-- occurrence is returned.
-- See Note [Kind and type-variable binders]
extractHsTyRdrTyVarsKindVars :: LHsType GhcPs -> RnM [Located RdrName]
extractHsTyRdrTyVarsKindVars ty
  = freeKiTyVarsKindVars <$> extractHsTyRdrTyVars ty

-- | Extracts free type and kind variables from types in a list.
-- When the same name occurs multiple times in the types, only the first
-- occurrence is returned and the rest is filtered out.
-- See Note [Kind and type-variable binders]
extractHsTysRdrTyVars :: [LHsType GhcPs] -> RnM FreeKiTyVarsNoDups
extractHsTysRdrTyVars tys
  = rmDupsInRdrTyVars <$> extractHsTysRdrTyVarsDups tys

-- | Extracts free type and kind variables from types in a list.
-- When the same name occurs multiple times in the types, all occurrences
-- are returned.
extractHsTysRdrTyVarsDups :: [LHsType GhcPs] -> RnM FreeKiTyVarsWithDups
extractHsTysRdrTyVarsDups tys
  = extract_ltys TypeLevel tys emptyFKTV

extractHsTyVarBndrsKVs :: [LHsTyVarBndr GhcPs] -> RnM [Located RdrName]
-- Returns the free kind variables of any explictly-kinded binders
-- NB: Does /not/ delete the binders themselves.
--     However duplicates are removed
--     E.g. given  [k1, a:k1, b:k2]
--          the function returns [k1,k2], even though k1 is bound here
extractHsTyVarBndrsKVs tv_bndrs
  = do { kvs <- extract_hs_tv_bndrs_kvs tv_bndrs
       ; return (nubL kvs) }

-- | Removes multiple occurrences of the same name from FreeKiTyVars. If a
-- variable occurs as both a kind and a type variable, only keep the occurrence
-- as a kind variable.
-- See also Note [Kind and type-variable binders]
rmDupsInRdrTyVars :: FreeKiTyVarsWithDups -> FreeKiTyVarsNoDups
rmDupsInRdrTyVars (FKTV kis tys)
  = FKTV kis' tys'
  where
    kis' = nubL kis
    tys' = nubL (filterOut (`elemRdr` kis') tys)

extractRdrKindSigVars :: LFamilyResultSig GhcPs -> RnM [Located RdrName]
extractRdrKindSigVars (L _ resultSig)
    | KindSig k                        <- resultSig = kindRdrNameFromSig k
    | TyVarSig (L _ (KindedTyVar _ _ k)) <- resultSig = kindRdrNameFromSig k
    | otherwise = return []
    where kindRdrNameFromSig k = freeKiTyVarsAllVars <$> extractHsTyRdrTyVars k

extractDataDefnKindVars :: HsDataDefn GhcPs -> RnM [Located RdrName]
-- Get the scoped kind variables mentioned free in the constructor decls
-- Eg: data T a = T1 (S (a :: k) | forall (b::k). T2 (S b)
--     Here k should scope over the whole definition
--
-- However, do NOT collect free kind vars from the deriving clauses:
-- Eg: (Trac #14331)    class C p q
--                      data D = D deriving ( C (a :: k) )
--     Here k should /not/ scope over the whole definition.  We intend
--     this to elaborate to:
--         class C @k1 @k2 (p::k1) (q::k2)
--         data D = D
--         instance forall k (a::k). C @k @* a D where ...
--
extractDataDefnKindVars (HsDataDefn { dd_ctxt = ctxt, dd_kindSig = ksig
                                    , dd_cons = cons })
  = (nubL . freeKiTyVarsKindVars) <$>
    (extract_lctxt TypeLevel ctxt =<<
     extract_mb extract_lkind ksig =<<
     foldrM (extract_con . unLoc) emptyFKTV cons)
  where
    extract_con (ConDeclGADT { }) acc = return acc
    extract_con (ConDeclH98 { con_ex_tvs = ex_tvs
                            , con_mb_cxt = ctxt, con_args = args }) acc
      = extract_hs_tv_bndrs ex_tvs acc =<<
        extract_mlctxt ctxt =<<
        extract_ltys TypeLevel (hsConDeclArgTys args) emptyFKTV

extract_mlctxt :: Maybe (LHsContext GhcPs)
               -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_mlctxt Nothing     acc = return acc
extract_mlctxt (Just ctxt) acc = extract_lctxt TypeLevel ctxt acc

extract_lctxt :: TypeOrKind
              -> LHsContext GhcPs
              -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_lctxt t_or_k ctxt = extract_ltys t_or_k (unLoc ctxt)

extract_ltys :: TypeOrKind
             -> [LHsType GhcPs]
             -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_ltys t_or_k tys acc = foldrM (extract_lty t_or_k) acc tys

extract_mb :: (a -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups)
           -> Maybe a
           -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_mb _ Nothing  acc = return acc
extract_mb f (Just x) acc = f x acc

extract_lkind :: LHsType GhcPs -> FreeKiTyVars -> RnM FreeKiTyVars
extract_lkind = extract_lty KindLevel

extract_lty :: TypeOrKind -> LHsType GhcPs
            -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_lty t_or_k (L _ ty) acc
  = case ty of
      HsTyVar _ _  ltv            -> extract_tv t_or_k ltv acc
      HsBangTy _ _ ty             -> extract_lty t_or_k ty acc
      HsRecTy _ flds              -> foldrM (extract_lty t_or_k
                                             . cd_fld_type . unLoc) acc
                                           flds
      HsAppsTy _ tys              -> extract_apps t_or_k tys acc
      HsAppTy _ ty1 ty2           -> extract_lty t_or_k ty1 =<<
                                     extract_lty t_or_k ty2 acc
      HsListTy _ ty               -> extract_lty t_or_k ty acc
      HsPArrTy _ ty               -> extract_lty t_or_k ty acc
      HsTupleTy _ _ tys           -> extract_ltys t_or_k tys acc
      HsSumTy _ tys               -> extract_ltys t_or_k tys acc
      HsFunTy _ ty1 ty2           -> extract_lty t_or_k ty1 =<<
                                     extract_lty t_or_k ty2 acc
      HsIParamTy _ _ ty           -> extract_lty t_or_k ty acc
      HsEqTy _ ty1 ty2            -> extract_lty t_or_k ty1 =<<
                                     extract_lty t_or_k ty2 acc
      HsOpTy _ ty1 tv ty2         -> extract_tv t_or_k tv =<<
                                     extract_lty t_or_k ty1 =<<
                                     extract_lty t_or_k ty2 acc
      HsParTy _ ty                -> extract_lty t_or_k ty acc
      HsSpliceTy {}               -> return acc  -- Type splices mention no tvs
      HsDocTy _ ty _              -> extract_lty t_or_k ty acc
      HsExplicitListTy _ _ tys    -> extract_ltys t_or_k tys acc
      HsExplicitTupleTy _ tys     -> extract_ltys t_or_k tys acc
      HsTyLit _ _                 -> return acc
      HsKindSig _ ty ki           -> extract_lty t_or_k ty =<<
                                     extract_lkind ki acc
      HsForAllTy { hst_bndrs = tvs, hst_body = ty }
                                  -> extract_hs_tv_bndrs tvs acc =<<
                                     extract_lty t_or_k ty emptyFKTV
      HsQualTy { hst_ctxt = ctxt, hst_body = ty }
                                  -> extract_lctxt t_or_k ctxt   =<<
                                     extract_lty t_or_k ty acc
      XHsType {}                  -> return acc
      -- We deal with these separately in rnLHsTypeWithWildCards
      HsWildCardTy {}             -> return acc

extract_apps :: TypeOrKind
             -> [LHsAppType GhcPs] -> FreeKiTyVars -> RnM FreeKiTyVars
extract_apps t_or_k tys acc = foldrM (extract_app t_or_k) acc tys

extract_app :: TypeOrKind -> LHsAppType GhcPs
            -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_app t_or_k (L _ (HsAppInfix _ tv))  acc = extract_tv t_or_k tv acc
extract_app t_or_k (L _ (HsAppPrefix _ ty)) acc = extract_lty t_or_k ty acc
extract_app _ (L _ (XAppType _ )) _ = panic "extract_app"

extractHsTvBndrs :: [LHsTyVarBndr GhcPs]
                 -> FreeKiTyVarsWithDups           -- Free in body
                 -> RnM FreeKiTyVarsWithDups       -- Free in result
extractHsTvBndrs tv_bndrs body_fvs
  = extract_hs_tv_bndrs tv_bndrs emptyFKTV body_fvs

extract_hs_tv_bndrs :: [LHsTyVarBndr GhcPs]
                    -> FreeKiTyVarsWithDups  -- Accumulator
                    -> FreeKiTyVarsWithDups  -- Free in body
                    -> RnM FreeKiTyVarsWithDups
-- In (forall (a :: Maybe e). a -> b) we have
--     'a' is bound by the forall
--     'b' is a free type variable
--     'e' is a free kind variable
extract_hs_tv_bndrs tv_bndrs
                    (FKTV acc_kvs  acc_tvs)   -- Accumulator
                    (FKTV body_kvs body_tvs)  -- Free in the body
  | null tv_bndrs
  = return $
    FKTV (body_kvs ++ acc_kvs) (body_tvs ++ acc_tvs)
  | otherwise
  = do { bndr_kvs <- extract_hs_tv_bndrs_kvs tv_bndrs

       ; let tv_bndr_rdrs :: [Located RdrName]
             tv_bndr_rdrs = map hsLTyVarLocName tv_bndrs

       ; traceRn "checkMixedVars1" $
           vcat [ text "body_kvs"     <+> ppr body_kvs
                , text "tv_bndr_rdrs" <+> ppr tv_bndr_rdrs ]
       ; checkMixedVars body_kvs tv_bndr_rdrs

       ; return $
         FKTV (filterOut (`elemRdr` tv_bndr_rdrs) (bndr_kvs ++ body_kvs)
                    -- NB: delete all tv_bndr_rdrs from bndr_kvs as well
                    -- as body_kvs; see Note [Kind variable scoping]
                ++ acc_kvs)
              (filterOut (`elemRdr` tv_bndr_rdrs) body_tvs ++ acc_tvs) }

extract_hs_tv_bndrs_kvs :: [LHsTyVarBndr GhcPs] -> RnM [Located RdrName]
-- Returns the free kind variables of any explictly-kinded binders
-- NB: Does /not/ delete the binders themselves.
--     Duplicates are /not/ removed
--     E.g. given  [k1, a:k1, b:k2]
--          the function returns [k1,k2], even though k1 is bound here
extract_hs_tv_bndrs_kvs tv_bndrs
  = do { fktvs <- foldrM extract_lkind emptyFKTV
                  [k | L _ (KindedTyVar _ _ k) <- tv_bndrs]
       ; return (freeKiTyVarsKindVars fktvs) }
         -- There will /be/ no free tyvars!

extract_tv :: TypeOrKind -> Located RdrName
           -> FreeKiTyVarsWithDups -> RnM FreeKiTyVarsWithDups
extract_tv t_or_k ltv@(L _ tv) acc@(FKTV kvs tvs)
  | not (isRdrTyVar tv) = return acc
  | isTypeLevel t_or_k  = return (FKTV kvs (ltv : tvs))
  | otherwise           = return (FKTV (ltv : kvs) tvs)

-- just used in this module; seemed convenient here
nubL :: Eq a => [Located a] -> [Located a]
nubL = nubBy eqLocated

elemRdr :: Located RdrName -> [Located RdrName] -> Bool
elemRdr x = any (eqLocated x)

checkMixedVars :: [Located RdrName] -> [Located RdrName] -> RnM ()
-- In (checkMixedVars kvs tvs) we are about to bind the type
-- variables tvs, and kvs is the set of free variables of the kinds
-- in the scope of the binding.  E.g.
--    forall a b. a -> (b::k) -> (c::a)
-- Here tv will be {a,b}, and kvs {k,a}.
-- Without -XTypeInType we want to complain that 'a' is used both
-- as a type and a kind.
--
-- Specifically, check that there is no overlap between kvs and tvs
-- See typecheck/should_fail/T11963 for examples
--
-- NB: we do this only at the binding site of 'tvs'.
checkMixedVars kvs tvs
  = do { type_in_type <- xoptM LangExt.TypeInType
       ; unless type_in_type $
         mapM_ check kvs }
  where
    check kv = when (kv `elemRdr` tvs) $
               addErrAt (getLoc kv) $
               vcat [ text "Variable" <+> quotes (ppr kv)
                      <+> text "used as both a kind and a type"
                    , text "Did you intend to use TypeInType?" ]
