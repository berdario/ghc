%
% (c) The AQUA Project, Glasgow University, 1998
%
\section[StdIdInfo]{Standard unfoldings}

This module contains definitions for the IdInfo for things that
have a standard form, namely:

	* data constructors
	* record selectors
	* method and superclass selectors
	* primitive operations

\begin{code}
module MkId (
	mkSpecPragmaId,	mkWorkerId,

	mkDictFunId, mkDefaultMethodId,
	mkMethodSelId, mkSuperDictSelId, 

	mkDataConId,
	mkRecordSelId,
	mkNewTySelId,
	mkPrimitiveId
    ) where

#include "HsVersions.h"

import {-# SOURCE #-} CoreUnfold ( mkUnfolding )

import TysWiredIn	( boolTy )
import Type		( Type, ThetaType,
			  mkDictTy, mkTyConApp, mkTyVarTys, mkFunTys, mkFunTy, mkSigmaTy,
			  isUnLiftedType, substTopTheta,
			  splitSigmaTy, splitFunTy_maybe, splitAlgTyConApp,
			  splitFunTys, splitForAllTys
			)
import TyCon		( TyCon, isNewTyCon, tyConDataCons, isDataTyCon )
import Class		( Class, classBigSig, classTyCon )
import Var		( Id, TyVar, VarDetails(..), mkId )
import VarEnv		( zipVarEnv )
import Const		( Con(..) )
import Name		( mkDerivedName, mkWiredInIdName, 
			  mkWorkerOcc, mkSuperDictSelOcc,
			  Name, NamedThing(..),
			)
import PrimOp		( PrimOp, primOpType, primOpOcc, primOpUniq )
import DataCon		( DataCon, dataConStrictMarks, dataConFieldLabels, 
			  dataConArgTys, dataConSig, dataConRawArgTys
			)
import Id		( idType,
			  mkUserLocal, mkVanillaId, mkTemplateLocals,
			  mkTemplateLocal, setInlinePragma
			)
import IdInfo		( noIdInfo,
			  exactArity, setUnfoldingInfo, 
			  setArityInfo, setInlinePragInfo,
			  InlinePragInfo(..), IdInfo
			)
import FieldLabel	( FieldLabel, FieldLabelTag, mkFieldLabel, fieldLabelName, 
			  firstFieldLabelTag, allFieldLabelTags
			)
import CoreSyn
import PrelVals		( rEC_SEL_ERROR_ID )
import PrelMods		( pREL_GHC )
import Maybes
import BasicTypes	( Arity, StrictnessMark(..) )
import Unique		( Unique )
import Maybe            ( isJust )
import Outputable
import Util		( assoc )
import List		( nub )
\end{code}		


%************************************************************************
%*									*
\subsection{Easy ones}
%*									*
%************************************************************************

\begin{code}
mkSpecPragmaId occ uniq ty loc
  = mkUserLocal occ uniq ty loc `setInlinePragma` IAmASpecPragmaId
	-- Maybe a SysLocal?  But then we'd lose the location

mkDefaultMethodId dm_name rec_c ty
  = mkVanillaId dm_name ty

mkWorkerId uniq unwrkr ty
  = mkVanillaId (mkDerivedName mkWorkerOcc (getName unwrkr) uniq) ty
\end{code}

%************************************************************************
%*									*
\subsection{Data constructors}
%*									*
%************************************************************************

\begin{code}
mkDataConId :: DataCon -> Id
mkDataConId data_con
  = mkId (getName data_con)
	 id_ty
	 (ConstantId (DataCon data_con))
	 (dataConInfo data_con)
  where
    (tyvars, theta, ex_tyvars, ex_theta, arg_tys, tycon) = dataConSig data_con
    id_ty = mkSigmaTy (tyvars ++ ex_tyvars) 
	              (theta ++ ex_theta)
	              (mkFunTys arg_tys (mkTyConApp tycon (mkTyVarTys tyvars)))
\end{code}

We're going to build a constructor that looks like:

	data (Data a, C b) =>  T a b = T1 !a !Int b

	T1 = /\ a b -> 
	     \d1::Data a, d2::C b ->
	     \p q r -> case p of { p ->
		       case q of { q ->
		       Con T1 [a,b] [p,q,r]}}

Notice that

* d2 is thrown away --- a context in a data decl is used to make sure
  one *could* construct dictionaries at the site the constructor
  is used, but the dictionary isn't actually used.

* We have to check that we can construct Data dictionaries for
  the types a and Int.  Once we've done that we can throw d1 away too.

* We use (case p of ...) to evaluate p, rather than "seq" because
  all that matters is that the arguments are evaluated.  "seq" is 
  very careful to preserve evaluation order, which we don't need
  to be here.

\begin{code}
dataConInfo :: DataCon -> IdInfo

dataConInfo data_con
  = setInlinePragInfo IMustBeINLINEd $ -- Always inline constructors
    setArityInfo (exactArity (n_dicts + n_ex_dicts + n_id_args)) $
    setUnfoldingInfo unfolding $
    noIdInfo
  where
        unfolding = mkUnfolding con_rhs

	(tyvars, theta, ex_tyvars, ex_theta, orig_arg_tys, tycon) 
	   = dataConSig data_con
	rep_arg_tys = dataConRawArgTys data_con
	all_tyvars   = tyvars ++ ex_tyvars

	dict_tys     = [mkDictTy clas tys | (clas,tys) <- theta]
	ex_dict_tys  = [mkDictTy clas tys | (clas,tys) <- ex_theta]

	n_dicts	     = length dict_tys
	n_ex_dicts   = length ex_dict_tys
	n_id_args    = length orig_arg_tys
 	n_rep_args   = length rep_arg_tys

	result_ty    = mkTyConApp tycon (mkTyVarTys tyvars)

	mkLocals i n tys   = (zipWith mkTemplateLocal [i..i+n-1] tys, i+n)
	(dict_args, i1)    = mkLocals 1  n_dicts    dict_tys
	(ex_dict_args,i2)  = mkLocals i1 n_ex_dicts ex_dict_tys
	(id_args,i3)       = mkLocals i2 n_id_args  orig_arg_tys

	(id_arg1:_) = id_args		-- Used for newtype only
	strict_marks  = dataConStrictMarks data_con

	con_app i rep_ids
                | isNewTyCon tycon 
		= ASSERT( length orig_arg_tys == 1 )
		  Note (Coerce result_ty (head orig_arg_tys)) (Var id_arg1)
 		| otherwise
		= mkConApp data_con 
			(map Type (mkTyVarTys all_tyvars) ++ 
			 map Var (reverse rep_ids))

	con_rhs = mkLams all_tyvars $ mkLams dict_args $ 
		  mkLams ex_dict_args $ mkLams id_args $
		  foldr mk_case con_app 
		     (zip (ex_dict_args++id_args) strict_marks) i3 []

	mk_case 
	   :: (Id, StrictnessMark)	-- arg, strictness
	   -> (Int -> [Id] -> CoreExpr) -- body
	   -> Int			-- next rep arg id
	   -> [Id]			-- rep args so far
	   -> CoreExpr
	mk_case (arg,strict) body i rep_args
  	  = case strict of
		NotMarkedStrict -> body i (arg:rep_args)
		MarkedStrict 
		   | isUnLiftedType (idType arg) -> body i (arg:rep_args)
		   | otherwise ->
			Case (Var arg) arg [(DEFAULT,[], body i (arg:rep_args))]

		MarkedUnboxed con tys ->
		   Case (Var arg) arg [(DataCon con, con_args,
					body i' (reverse con_args++rep_args))]
		   where n_tys = length tys
			 (con_args,i') = mkLocals i (length tys) tys
\end{code}


%************************************************************************
%*									*
\subsection{Record selectors}
%*									*
%************************************************************************

We're going to build a record selector unfolding that looks like this:

	data T a b c = T1 { ..., op :: a, ...}
		     | T2 { ..., op :: a, ...}
		     | T3

	sel = /\ a b c -> \ d -> case d of
				    T1 ... x ... -> x
				    T2 ... x ... -> x
				    other	 -> error "..."

\begin{code}
mkRecordSelId field_label selector_ty
  = ASSERT( null theta && isDataTyCon tycon )
    sel_id
  where
    sel_id = mkId (fieldLabelName field_label) selector_ty
		  (RecordSelId field_label) info

    info = exactArity 1	`setArityInfo` (
	   unfolding	`setUnfoldingInfo`
	   noIdInfo)
	-- ToDo: consider adding further IdInfo

    unfolding = mkUnfolding sel_rhs

    (tyvars, theta, tau)  = splitSigmaTy selector_ty
    (data_ty,rhs_ty)      = expectJust "StdIdInfoRec" (splitFunTy_maybe tau)
					-- tau is of form (T a b c -> field-type)
    (tycon, _, data_cons) = splitAlgTyConApp data_ty
    tyvar_tys	          = mkTyVarTys tyvars
	
    [data_id] = mkTemplateLocals [data_ty]
    alts      = map mk_maybe_alt data_cons
    the_alts  = catMaybes alts
    default_alt | all isJust alts = []	-- No default needed
		| otherwise	  = [(DEFAULT, [], error_expr)]

    sel_rhs   = mkLams tyvars $ Lam data_id $
		Case (Var data_id) data_id (the_alts ++ default_alt)

    mk_maybe_alt data_con 
	  = case maybe_the_arg_id of
		Nothing		-> Nothing
		Just the_arg_id -> Just (DataCon data_con, arg_ids, Var the_arg_id)
	  where
	    arg_ids 	     = mkTemplateLocals (dataConArgTys data_con tyvar_tys)
				    -- The first one will shadow data_id, but who cares
	    field_lbls	     = dataConFieldLabels data_con
	    maybe_the_arg_id = assocMaybe (field_lbls `zip` arg_ids) field_label

    error_expr = mkApps (Var rEC_SEL_ERROR_ID) [Type rhs_ty, mkStringLit full_msg]
    full_msg   = showSDoc (sep [text "No match in record selector", ppr sel_id]) 
\end{code}


%************************************************************************
%*									*
\subsection{Newtype field selectors}
%*									*
%************************************************************************

Possibly overkill to do it this way:

\begin{code}
mkNewTySelId field_label selector_ty = sel_id
  where
    sel_id = mkId (fieldLabelName field_label) selector_ty
		  (RecordSelId field_label) info

    info = exactArity 1	`setArityInfo` (
	   unfolding	`setUnfoldingInfo`
	   noIdInfo)
	-- ToDo: consider adding further IdInfo

    unfolding = mkUnfolding sel_rhs

    (tyvars, theta, tau)  = splitSigmaTy selector_ty
    (data_ty,rhs_ty)      = expectJust "StdIdInfoRec" (splitFunTy_maybe tau)
					-- tau is of form (T a b c -> field-type)
    (tycon, _, data_cons) = splitAlgTyConApp data_ty
    tyvar_tys	          = mkTyVarTys tyvars
	
    [data_id] = mkTemplateLocals [data_ty]
    sel_rhs   = mkLams tyvars $ Lam data_id $
		Note (Coerce rhs_ty data_ty) (Var data_id)

\end{code}


%************************************************************************
%*									*
\subsection{Dictionary selectors}
%*									*
%************************************************************************

\begin{code}
mkSuperDictSelId :: Unique -> Class -> FieldLabelTag -> Type -> Id
	-- The FieldLabelTag says which superclass is selected
	-- So, for 
	--	class (C a, C b) => Foo a b where ...
	-- we get superclass selectors
	--	Foo_sc1, Foo_sc2

mkSuperDictSelId uniq clas index ty
  = mkDictSelId name clas ty
  where
    name   = mkDerivedName (mkSuperDictSelOcc index) (getName clas) uniq

	-- For method selectors the clean thing to do is
	-- to give the method selector the same name as the class op itself.
mkMethodSelId name clas ty
  = mkDictSelId name clas ty
\end{code}

Selecting a field for a dictionary.  If there is just one field, then
there's nothing to do.

\begin{code}
mkDictSelId name clas ty
  = sel_id
  where
    sel_id    = mkId name ty (RecordSelId field_lbl) info
    field_lbl = mkFieldLabel name ty tag
    tag       = assoc "MkId.mkDictSelId" ((sc_sel_ids ++ op_sel_ids) `zip` allFieldLabelTags) sel_id

    info      = setInlinePragInfo IMustBeINLINEd $
		setUnfoldingInfo  unfolding noIdInfo
	-- The always-inline thing means we don't need any other IdInfo
	-- We need "Must" inline because we don't create any bindigs for
	-- the selectors.

    unfolding = mkUnfolding rhs

    (tyvars, _, sc_sel_ids, op_sel_ids, defms) = classBigSig clas

    tycon      = classTyCon clas
    [data_con] = tyConDataCons tycon
    tyvar_tys  = mkTyVarTys tyvars
    arg_tys    = dataConArgTys data_con tyvar_tys
    the_arg_id = arg_ids !! (tag - firstFieldLabelTag)

    dict_ty    = mkDictTy clas tyvar_tys
    (dict_id:arg_ids) = mkTemplateLocals (dict_ty : arg_tys)

    rhs | isNewTyCon tycon = mkLams tyvars $ Lam dict_id $
			     Note (Coerce (head arg_tys) dict_ty) (Var dict_id)
	| otherwise	   = mkLams tyvars $ Lam dict_id $
			     Case (Var dict_id) dict_id
			     	  [(DataCon data_con, arg_ids, Var the_arg_id)]
\end{code}


%************************************************************************
%*									*
\subsection{Primitive operations
%*									*
%************************************************************************


\begin{code}
mkPrimitiveId :: PrimOp -> Id
mkPrimitiveId prim_op 
  = id
  where
    occ_name = primOpOcc  prim_op
    key	     = primOpUniq prim_op
    ty	     = primOpType prim_op
    name    = mkWiredInIdName key pREL_GHC occ_name id
    id      = mkId name ty (ConstantId (PrimOp prim_op)) info
		
    info = setUnfoldingInfo unfolding $
	   setInlinePragInfo IMustBeINLINEd $
		-- The pragma @IMustBeINLINEd@ says that this Id absolutely 
		-- must be inlined.  It's only used for primitives, 
		-- because we don't want to make a closure for each of them.
	   noIdInfo

    unfolding = mkUnfolding rhs

    (tyvars, tau) = splitForAllTys ty
    (arg_tys, _)  = splitFunTys tau

    args = mkTemplateLocals arg_tys
    rhs =  mkLams tyvars $ mkLams args $
	   mkPrimApp prim_op (map Type (mkTyVarTys tyvars) ++ map Var args)
\end{code}

\end{code}

\begin{code}
dyadic_fun_ty  ty = mkFunTys [ty, ty] ty
monadic_fun_ty ty = ty `mkFunTy` ty
compare_fun_ty ty = mkFunTys [ty, ty] boolTy
\end{code}


%************************************************************************
%*									*
\subsection{DictFuns}
%*									*
%************************************************************************

\begin{code}
mkDictFunId :: Name		-- Name to use for the dict fun;
	    -> Class 
	    -> [TyVar]
	    -> [Type]
	    -> ThetaType
	    -> Id

mkDictFunId dfun_name clas inst_tyvars inst_tys inst_decl_theta
  = mkVanillaId dfun_name dfun_ty
  where
    (class_tyvars, sc_theta, _, _, _) = classBigSig clas
    sc_theta' = substTopTheta (zipVarEnv class_tyvars inst_tys) sc_theta

    dfun_theta = case inst_decl_theta of
		   []    -> []	-- If inst_decl_theta is empty, then we don't
				-- want to have any dict arguments, so that we can
				-- expose the constant methods.

		   other -> nub (inst_decl_theta ++ sc_theta')
				-- Otherwise we pass the superclass dictionaries to
				-- the dictionary function; the Mark Jones optimisation.
				--
				-- NOTE the "nub".  I got caught by this one:
				--   class Monad m => MonadT t m where ...
				--   instance Monad m => MonadT (EnvT env) m where ...
				-- Here, the inst_decl_theta has (Monad m); but so
				-- does the sc_theta'!

    dfun_ty = mkSigmaTy inst_tyvars dfun_theta (mkDictTy clas inst_tys)
\end{code}
