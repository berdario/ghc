%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[TcMonoType]{Typechecking user-specified @MonoTypes@}

\begin{code}
#include "HsVersions.h"

module TcMonoType ( tcHsType, tcHsTypeKind, tcContext, tcTyVarScope ) where

IMP_Ubiq(){-uitous-}

import HsSyn		( HsType(..), HsTyVar(..), Fake )
import RnHsSyn		( RenamedHsType(..), RenamedContext(..) )

import TcMonad
import TcEnv		( tcLookupTyVar, tcLookupClass, tcLookupTyCon, tcExtendTyVarEnv	)
import TcKind		( TcKind, mkTcTypeKind, mkBoxedTypeKind,
			  mkTcArrowKind, unifyKind, newKindVar,
			  kindToTcKind, tcDefaultKind
			)
import Type		( GenType, SYN_IE(Type), SYN_IE(ThetaType), 
			  mkTyVarTy, mkTyConTy, mkFunTy, mkAppTy, mkSynTy,
			  mkSigmaTy, mkDictTy
			)
import TyVar		( GenTyVar, SYN_IE(TyVar), mkTyVar )
import PrelInfo		( cCallishClassKeys )
import TyCon		( TyCon )
import Name		( Name, OccName, isTvOcc )
import TysWiredIn	( mkListTy, mkTupleTy )
import Unique		( Unique )
import PprStyle
import Pretty
import Util		( zipWithEqual, zipLazy, panic{-, pprPanic ToDo:rm-} )
\end{code}


tcHsType and tcHsTypeKind
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

tcHsType checks that the type really is of kind Type!

\begin{code}
tcHsType :: RenamedHsType -> TcM s Type

tcHsType ty
  = tcHsTypeKind ty			`thenTc` \ (kind,ty) ->
    unifyKind kind mkTcTypeKind		`thenTc_`
    returnTc ty
\end{code}

tcHsTypeKind does the real work.  It returns a kind and a type.

\begin{code}
tcHsTypeKind :: RenamedHsType -> TcM s (TcKind s, Type)

tcHsTypeKind (MonoTyVar name)
  = tcLookupTyVar name	`thenNF_Tc` \ (kind,tyvar) ->
    returnTc (kind, mkTyVarTy tyvar)
    

tcHsTypeKind (MonoListTy _ ty)
  = tcHsType ty	`thenTc` \ tau_ty ->
    returnTc (mkTcTypeKind, mkListTy tau_ty)

tcHsTypeKind (MonoTupleTy _ tys)
  = mapTc tcHsType  tys	`thenTc` \ tau_tys ->
    returnTc (mkTcTypeKind, mkTupleTy (length tys) tau_tys)

tcHsTypeKind (MonoFunTy ty1 ty2)
  = tcHsType ty1	`thenTc` \ tau_ty1 ->
    tcHsType ty2	`thenTc` \ tau_ty2 ->
    returnTc (mkTcTypeKind, mkFunTy tau_ty1 tau_ty2)

tcHsTypeKind (MonoTyApp name tys)
  | isTvOcc (getOccName name)	-- Must be a type variable
  = tcLookupTyVar name			`thenNF_Tc` \ (kind,tyvar) ->
    tcMonoTyApp kind (mkTyVarTy tyvar) tys

  | otherwise		 	-- Must be a type constructor
  = tcLookupTyCon name			`thenTc` \ (kind,maybe_arity,tycon) ->
    case maybe_arity of
	Just arity -> tcSynApp name kind arity tycon tys	-- synonum
	Nothing	   -> tcMonoTyApp kind (mkTyConTy tycon) tys	-- newtype or data

tcHsTypeKind (HsForAllTy tv_names context ty)
  = tcTyVarScope tv_names		 	$ \ tyvars ->
	tcContext context			`thenTc` \ theta ->
	tcHsType ty				`thenTc` \ tau ->
		-- For-all's are of kind type!
	returnTc (mkTcTypeKind, mkSigmaTy tyvars theta tau)

-- for unfoldings only:
tcHsTypeKind (MonoDictTy class_name ty)
  = tcHsTypeKind ty			`thenTc` \ (arg_kind, arg_ty) ->
    tcLookupClass class_name		`thenTc` \ (class_kind, clas) ->
    unifyKind class_kind arg_kind	`thenTc_`
    returnTc (mkTcTypeKind, mkDictTy clas arg_ty)
\end{code}

Help functions for type applications
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
tcMonoTyApp fun_kind fun_ty tys
  = mapAndUnzipTc tcHsTypeKind tys	`thenTc`    \ (arg_kinds, arg_tys) ->
    newKindVar				`thenNF_Tc` \ result_kind ->
    unifyKind fun_kind (foldr mkTcArrowKind result_kind arg_kinds)	`thenTc_`
    returnTc (result_kind, foldl mkAppTy fun_ty arg_tys)

tcSynApp name syn_kind arity tycon tys
  = mapAndUnzipTc tcHsTypeKind tys	`thenTc`    \ (arg_kinds, arg_tys) ->
    newKindVar				`thenNF_Tc` \ result_kind ->
    unifyKind syn_kind (foldr mkTcArrowKind result_kind arg_kinds)	`thenTc_`

	-- Check that it's applied to the right number of arguments
    checkTc (arity == n_args) (err arity)				`thenTc_`
    returnTc (result_kind, mkSynTy tycon arg_tys)
  where
    err arity = arityErr "Type synonym constructor" name arity n_args
    n_args    = length tys
\end{code}


Contexts
~~~~~~~~
\begin{code}

tcContext :: RenamedContext -> TcM s ThetaType
tcContext context = mapTc tcClassAssertion context

tcClassAssertion (class_name, ty)
  = checkTc (canBeUsedInContext class_name)
	    (naughtyCCallContextErr class_name)	`thenTc_`

    tcLookupClass class_name		`thenTc` \ (class_kind, clas) ->
    tcHsTypeKind ty			`thenTc` \ (ty_kind, ty) ->

    unifyKind class_kind ty_kind	`thenTc_`

    returnTc (clas, ty)
\end{code}

HACK warning: Someone discovered that @CCallable@ and @CReturnable@
could be used in contexts such as:
\begin{verbatim}
foo :: CCallable a => a -> PrimIO Int
\end{verbatim}

Doing this utterly wrecks the whole point of introducing these
classes so we specifically check that this isn't being done.

\begin{code}
canBeUsedInContext :: Name -> Bool
canBeUsedInContext n = not (uniqueOf n `elem` cCallishClassKeys)
\end{code}

Type variables, with knot tying!
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
tcTyVarScope
	:: [HsTyVar Name]		-- Names of some type variables
	-> ([TyVar] -> TcM s a)		-- Thing to type check in their scope
	-> TcM s a			-- Result

tcTyVarScope tyvar_names thing_inside
  = mapAndUnzipNF_Tc tcHsTyVar tyvar_names	`thenNF_Tc` \ (names, kinds) ->

    fixTc (\ ~(rec_tyvars, _) ->
		-- Ok to look at names, kinds, but not tyvars!

	tcExtendTyVarEnv names (kinds `zipLazy` rec_tyvars)
			 (thing_inside rec_tyvars)		`thenTc` \ result ->
 
		-- Get the tyvar's Kinds from their TcKinds
	mapNF_Tc tcDefaultKind kinds				`thenNF_Tc` \ kinds' ->

		-- Construct the real TyVars
	let
	  tyvars = zipWithEqual "tcTyVarScope" mkTyVar names kinds'
	in
	returnTc (tyvars, result)
    )					`thenTc` \ (_,result) ->
    returnTc result

tcHsTyVar (UserTyVar name)
  = newKindVar		`thenNF_Tc` \ tc_kind ->
    returnNF_Tc (name, tc_kind)
tcHsTyVar (IfaceTyVar name kind)
  = returnNF_Tc (name, kindToTcKind kind)
\end{code}

Errors and contexts
~~~~~~~~~~~~~~~~~~~
\begin{code}
naughtyCCallContextErr clas_name sty
  = ppSep [ppStr "Can't use class", ppr sty clas_name, ppStr "in a context"]
\end{code}
