%
% (c) The AQUA Project, Glasgow University, 1993-1996
%
\section[SimplPgm]{Interface to the simplifier}

\begin{code}
#include "HsVersions.h"

module SimplPgm ( simplifyPgm ) where

IMP_Ubiq(){-uitous-}

import CmdLineOpts	( opt_D_verbose_core2core,
			  switchIsOn, SimplifierSwitch(..)
			)
import CoreSyn
import CoreUnfold	( SimpleUnfolding )
import CoreUtils	( substCoreExpr )
import Id		( mkIdEnv, lookupIdEnv, SYN_IE(IdEnv),
			  GenId{-instance Ord3-}
			)
import Maybes		( catMaybes )
import OccurAnal	( occurAnalyseBinds )
import Pretty		( ppAboves, ppBesides, ppInt, ppChar, ppStr )
import SimplEnv
import SimplMonad
import Simplify		( simplTopBinds )
import TyVar		( nullTyVarEnv, SYN_IE(TyVarEnv) )
import UniqSupply	( thenUs, returnUs, mapUs, splitUniqSupply, SYN_IE(UniqSM) )
import Util		( isIn, isn'tIn, removeDups, pprTrace )
\end{code}

\begin{code}
simplifyPgm :: [CoreBinding]	-- input
	    -> (SimplifierSwitch->SwitchResult)
	    -> SimplCount	-- info about how many times
				-- each transformation has occurred
	    -> UniqSupply
	    -> ([CoreBinding],	-- output
		 Int,		-- info about how much happened
		 SimplCount)	-- accumulated simpl stats

simplifyPgm binds s_sw_chkr simpl_stats us
  = case (splitUniqSupply us)		     of { (s1, s2) ->
    case (initSmpl s1 (simpl_pgm 0 1 binds)) of { ((pgm2, it_count, simpl_stats2), _) ->
    (pgm2, it_count, combineSimplCounts simpl_stats simpl_stats2) }}
  where
    simpl_switch_is_on  = switchIsOn s_sw_chkr

    occur_anal = occurAnalyseBinds

    max_simpl_iterations = getSimplIntSwitch s_sw_chkr MaxSimplifierIterations

    simpl_pgm :: Int -> Int -> [CoreBinding] -> SmplM ([CoreBinding], Int, SimplCount)

    simpl_pgm n iterations pgm
      =	-- find out what top-level binders are used,
	-- and prepare to unfold all the "simple" bindings
	let
	    tagged_pgm = occur_anal pgm simpl_switch_is_on
	in
	      -- do the business
	simplTopBinds (nullSimplEnv s_sw_chkr) tagged_pgm `thenSmpl` \ new_pgm ->

	      -- Quit if we didn't actually do anything; otherwise,
	      -- try again (if suitable flags)

	simplCount				`thenSmpl` \ r ->
	detailedSimplCount			`thenSmpl` \ dr ->
	let
	    show_status = pprTrace "NewSimpl: " (ppAboves [
		ppBesides [ppInt iterations, ppChar '/', ppInt max_simpl_iterations],
		ppStr (showSimplCount dr)
--DEBUG:	, ppAboves (map (pprCoreBinding PprDebug) new_pgm)
		])
	in

	(if opt_D_verbose_core2core
	 || simpl_switch_is_on  ShowSimplifierProgress
	 then show_status
	 else id)

	(let stop_now = r == n {-nothing happened-}
		     || (if iterations > max_simpl_iterations then
			    (if max_simpl_iterations > 1 {-otherwise too boring-} then
				trace
				("NOTE: Simplifier still going after "++show max_simpl_iterations++" iterations; bailing out.")
			     else id)
			    True
			 else
			    False)
	in
	if stop_now then
	    returnSmpl (new_pgm, iterations, dr)
	else
	    simpl_pgm r (iterations + 1) new_pgm
	)
\end{code}

