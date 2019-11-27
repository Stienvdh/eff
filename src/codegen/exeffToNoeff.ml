open NoEffSyntax
open Types
open Typed

module TypeCheck = TypeChecker
module NoEff = NoEffSyntax
module ExEffTypes = Types
module ExEff = Typed
module EffectSet = Set.Make (CoreTypes.Effect)
module Sub = Substitution

type effect_set = EffectSet.t

type environment = TypeCheck.state

let typefail str = let message = ("ExEff-to-NoEff: " ^ str) in failwith message

let rec extend_pattern_type env pat ty =
  match pat with
  | PVar x -> TypeCheck.extend_var_types env x ty
  | PAs (p, x) -> extend_pattern_type (TypeCheck.extend_var_types env x ty) p ty
  | PTuple ps -> (
    match ty with 
    | ExEffTypes.Tuple tys -> extend_multiple_pats env ps tys
    | _ -> typefail "Ill-typed tuple" )
  | PConst c -> if (ExEffTypes.type_const c = ty) then env else (typefail "Ill-typed constant")
  | PRecord recs -> (
    match ty with
    | ExEffTypes.Tuple tys -> extend_multiple_pats env (Assoc.values_of recs) tys
    | _ -> typefail "Ill-typed tuple" )
  | PVariant (_, p) -> extend_pattern_type env p ty
  | PNonbinding -> env

and extend_multiple_pats env ps tys =
  match ps with 
  | [] -> if (tys = []) then env else (typefail "Ill-typed tuple")
  | x :: xs -> 
      if (tys = []) then (typefail "Ill-typed tuple") else (
        let (y::ys) = tys in
        let env' = extend_pattern_type env x y in
        extend_multiple_pats env' xs ys
      )


let rec type_elab state (env : environment) (ty : ExEffTypes.target_ty) =
  match ty with
  | ExEffTypes.TyParam x -> ( 
    match (Assoc.lookup x env.ty_param_skeletons) with
    | Some xtype -> (xtype, NoEff.NTyParam x)
    | None -> typefail "Variable out of scope" )
  | ExEffTypes.Apply (name, lst) ->
    let get_skel x = ( let (s, _) = type_elab state env x in s ) in
    let get_elab x = ( let (_, e) = type_elab state env x in e ) in
    let skels = List.map get_skel lst in
    let elabs = List.map get_elab lst in
    (ExEffTypes.SkelApply (name, skels), NoEff.NTyApply (name, elabs) )
  | ExEffTypes.Arrow (t, dirty) -> 
    let (ty1, elab1) = type_elab state env t in
    let (ty2, elab2) = dirty_elab state env dirty in
    (ExEffTypes.SkelArrow (ty1, ty2), NoEff.NTyArrow (elab1, elab2))
  | ExEffTypes.Handler ((type1, dirt1), (type2, dirt2)) ->
    let (ty1, elab1) = type_elab state env type1 in
    if (ExEffTypes.is_empty_dirt dirt1)
    (* Handler type - Case 1: empty input dirt *)
    then (
      let (ty2, elab2) = dirty_elab state env (type2, dirt2) in
      (ExEffTypes.SkelHandler (ty1, ty2), NoEff.NTyArrow (elab1, elab2))
    )
    (* Handler type - Case 2: non-empty input dirt *)
    else (
      let (ty2, elab2) = type_elab state env type2 in
      (ExEffTypes.SkelHandler (ty1, ty2), NoEff.NTyHandler (elab1, elab2))
    )
  | ExEffTypes.Tuple tys ->
    let ty_elab_list = List.map (type_elab state env) tys in
    (ExEffTypes.SkelTuple (List.map fst ty_elab_list),
     NoEff.NTyTuple (List.map snd ty_elab_list))
  | ExEffTypes.QualTy ( (t1, t2), ty) ->
    let (type1, elab1) = type_elab state env t1 in
    let (type2, elab2) = type_elab state env t2 in
    let (type3, elab3) = type_elab state env ty in
    (type3, NoEff.NTyQual ((elab1, elab2), elab3))
  | ExEffTypes.QualDirt (_, ty) -> type_elab state env ty
  | ExEffTypes.TySchemeTy (par, skel, ty) -> 
    let env' = TypeCheck.extend_ty_param_skeletons env par skel in
    let (t, elab) = type_elab state env' ty in
    (t, NoEff.NTyForall (par, elab))
  | ExEffTypes.TySchemeDirt (par, ty) -> 
    let env' = TypeCheck.extend_dirt_params env par in
    type_elab state env' ty
  | ExEffTypes.TySchemeSkel (par, ty) -> 
    let (t, elab) = type_elab state env ty in
    (ExEffTypes.ForallSkel (par, t), elab)
  | ExEffTypes.PrimTy ty -> (ExEffTypes.PrimSkel ty, prim_type_elab ty)

and prim_type_elab ty = 
  match ty with
  | ExEffTypes.IntTy -> NoEff.NTyPrim NInt
  | ExEffTypes.BoolTy -> NoEff.NTyPrim NBool
  | ExEffTypes.StringTy -> NoEff.NTyPrim NString
  | ExEffTypes.FloatTy -> NoEff.NTyPrim NFloat

and dirty_elab state env (ty, dirt) =
  let (skel, elab) = type_elab state env ty in
  if (ExEffTypes.is_empty_dirt dirt)
  then (skel, elab)
  else (skel, NoEff.NTyComp elab)

and pattern_elab p =
  match p with
  | PVar x -> NVar x
  | PAs (p, x) -> NAs (pattern_elab p, x)
  | PTuple ps -> NTuple (List.map pattern_elab ps)
  | PConst c -> NConst c
  | PRecord recs -> NoEff.NRecord (Assoc.map pattern_elab recs)
  | PVariant (l, p) -> NoEff.NVariant (l, pattern_elab p)
  | PNonbinding -> NNonBinding

and value_elab (state : ExplicitInfer.state) (env : environment) v =
  match v with
  | ExEff.Var x -> (
    match Assoc.lookup x env.var_types with
    | Some ty -> (ty, NoEff.NVar x)
    | None -> ( match TypingEnv.lookup state.gblCtxt x with
                     | Some ty -> (ty, NoEff.NVar x)
                     | None -> typefail "No type for variable found" ) )
  | ExEff.Const c -> (ExEffTypes.type_const c, NoEff.NConst c)
  | ExEff.Tuple vs -> 
    let type_elab_list = List.map (value_elab state env) vs in
    (ExEffTypes.Tuple (List.map fst type_elab_list),
     NoEff.NTuple (List.map snd type_elab_list))
  | ExEff.Lambda (p, t, c) -> 
    let (_, elab1) = type_elab state env t in
    let env' = extend_pattern_type env p t in
    let (type2, elab2) = comp_elab state env' c in
    (ExEffTypes.Arrow (t, type2),
     NoEff.NFun (pattern_elab p, elab1, elab2))
  | ExEff.Effect (e, (t1, t2)) ->
    let (_, elab1) = type_elab state env t1 in
    let (_, elab2) = type_elab state env t2 in
    (ExEffTypes.Arrow (t1, (t2, ExEffTypes.closed_dirt (EffectSet.singleton e))), 
     NoEff.NEffect (e, (elab1, elab2)))
  | ExEff.Handler h ->
    let (p, t, c) = h.value_clause in
    let (_, elabt) = type_elab state env t in
    let env' = extend_pattern_type env p t in
    let (typec, elabc) = comp_elab state env' c in

    if (Assoc.length h.effect_clauses = 0)
    (* Handler - Case 1 *)
    then (
      (ExEffTypes.Handler ( (t, ExEffTypes.empty_dirt), typec),
       NoEff.NFun (pattern_elab p, elabt, elabc))
      )
    else (
      let (ty, dirt) = typec in
      if (ExEffTypes.is_empty_dirt dirt)
      (* Handler - Case 2 *)
      then (
        let subst_cont_effect ((eff, (ty1, ty2)), (p1, p2, comp)) = 
          ( let (_, elab1) = type_elab state env ty1 in
          let (_, elab2) = type_elab state env ty2 in
          let env' = extend_pattern_type env p1 ty1 in
          let env'' = extend_pattern_type env' p2 (ExEffTypes.Arrow (ty2, (t, ExEffTypes.empty_dirt))) in
          let (_, elabcomp) = comp_elab state env'' comp in
            ((eff, (elab1, elab2)), (pattern_elab p1, NoEff.NCast ((pattern_elab p2), 
            (NoEff.NCoerArrow (NoEff.NCoerRefl (elab1),
             NoEff.NCoerUnsafe (NoEff.NCoerRefl (elab2))))), NoEff.NReturn elabcomp)) ) in
        let effectset = get_effectset (Assoc.to_list h.effect_clauses) in
        (  ExEffTypes.Handler ( (t, ExEffTypes.closed_dirt effectset), typec ),  
           NoEff.NHandler 
           {return_clause= (pattern_elab p, elabt, NoEff.NReturn elabc);
           effect_clauses= Assoc.map_of_list subst_cont_effect (Assoc.to_list h.effect_clauses)}
        )
      )
      (* Handler - Case 3 *)
      else (
        let elab_effect_clause ((eff, (ty1, ty2)), (p1, p2, comp)) = 
          let (_, elab1) = type_elab state env ty1 in
          let (_, elab2) = type_elab state env ty2 in
          let env' = extend_pattern_type env p1 ty1 in
          let env'' = extend_pattern_type env' p2 (ExEffTypes.Arrow (ty2, (t, ExEffTypes.empty_dirt))) in
          let (_, elabcomp) = comp_elab state env'' comp in
          ((eff, (elab1, elab2)), (pattern_elab p1, pattern_elab p2, elabcomp)) in

        let effectset = get_effectset (Assoc.to_list h.effect_clauses) in
        ( 
          ExEffTypes.Handler ( (t, ExEffTypes.closed_dirt effectset), typec ),
          NoEff.NHandler {return_clause= (pattern_elab p, elabt, elabc);
          effect_clauses= (Assoc.map_of_list elab_effect_clause (Assoc.to_list h.effect_clauses))}    
        )
      )
    )
  | ExEff.BigLambdaTy (par, skel, value) -> 
    let env' = TypeCheck.extend_ty_param_skeletons env par skel in
    let (ty, elab) = value_elab state env' value in
    (ExEffTypes.TySchemeTy (par, skel, ty), NoEff.NBigLambdaTy (par, elab))
  | ExEff.BigLambdaDirt (par, value) -> 
    let env' = TypeCheck.extend_dirt_params env par in
    let (ty, elab) = value_elab state env' value in
    (ExEffTypes.TySchemeDirt (par, ty), elab)
  | ExEff.BigLambdaSkel (par, value) -> 
    let env' = TypeCheck.extend_skel_params env par in
    let (ty, elab) = value_elab state env' value in
    (ExEffTypes.TySchemeSkel (par, ty), elab)
  | ExEff.CastExp (value, coer) -> 
    let (ty1, elab1) = value_elab state env value in
    let ((ty2, r), elab2) = coercion_elab_ty state env coer in
    if (ty1 = ty2) 
    then (r, NoEff.NCast (elab1, elab2))
    else typefail "Ill-typed cast"
  | ExEff.ApplyTyExp (value, ty) -> 
    let (tyv, elabv) = (
      match (value_elab state env value) with
      | (ExEffTypes.TySchemeTy (p,t,v), elab) -> (ExEffTypes.TySchemeTy (p,t,v), elab)
      | _ -> typefail "Ill-typed type application value"
    ) in
    let (skel, elabt) = type_elab state env ty in
    let ExEffTypes.TySchemeTy (pat, s, bigt) = tyv in
    ( subst_ty_param ty pat bigt,  NoEff.NTyAppl (elabv, elabt) )
  | ExEff.LambdaTyCoerVar (par, (ty1, ty2), value) ->
    let (_, elab1) = type_elab state env ty1 in
    let (_, elab2) = type_elab state env ty2 in
    let env' = TypeCheck.extend_ty_coer_types env par (ty1, ty2) in
    let (typev, elabv) = value_elab state env' v in
    ( ExEffTypes.QualTy ((ty1, ty2), typev),
      NoEff.NBigLambdaCoer (par, (elab1, elab2), elabv) )
  | ExEff.LambdaDirtCoerVar (par, (dirt1, dirt2), value) -> 
    let env' = TypeCheck.extend_dirt_coer_types env par (dirt1, dirt2) in
    let (typev, elabv) = value_elab state env' value
    in (ExEffTypes.QualDirt ((dirt1, dirt2), typev), elabv) 
  | ExEff.ApplyDirtExp (value, dirt) -> failwith "Dirt application should not happen"
  | ExEff.ApplySkelExp (value, skel) -> 
    let (tyv, elabv) = value_elab state env value in
    ( match tyv with
    | ExEffTypes.TySchemeSkel (s, t) -> 
      let sub = Sub.add_skel_param_substitution_e s skel in
      ( Sub.apply_substitutions_to_type sub t, elabv ) 
    | _ -> typefail "Ill-typed skeleton application" )
  | ExEff.ApplyTyCoercion (value, coer) -> 
    let ((ty1, ty2), elabc) = coercion_elab_ty state env coer in
    let (ty, elabv) = value_elab state env value in
      (
        match ty with
        | ExEffTypes.QualTy ((ty1', ty2'), t) -> 
          if (ty1 = ty1' && ty2 = ty2') then ( (t, NoEff.NApplyCoer (elabv, elabc)) )
          else (typefail "Ill-typed coercion application")
        | _ -> typefail "Ill-typed coercion application"
      ) 
  | ExEff.ApplyDirtCoercion (value, coer) ->
    let (ty, elabv) = value_elab state env value in
    let (dirt1, dirt2) = coer_elab_dirt state env coer in
    (
        match ty with
        | ExEffTypes.QualDirt ((dirt1', dirt2'), t) -> 
          if (dirt1' = dirt1 && dirt2' = dirt2) 
          then (t, elabv) 
          else (typefail "Ill-typed coercion application")
        | _ -> failwith "Ill-typed coercion application"
    )

and coercion_elab_ty state env coer = 
  match coer with
  | ExEff.ReflTy ty -> 
    let (_, tyelab) = type_elab state env ty in
    ( (ty, ty), NoEff.NCoerRefl tyelab )
  | ExEff.ArrowCoercion (tycoer, dirtycoer) ->
    let ( (tycoer2, tycoer1), tyelab ) = coercion_elab_ty state env tycoer in
    let ( (dcoer1, dcoer2), dirtyelab ) = coer_elab_dirty state env dirtycoer in
    ( (ExEffTypes.Arrow (tycoer1, dcoer1), ExEffTypes.Arrow (tycoer2, dcoer2)), NoEff.NCoerArrow (tyelab, dirtyelab) )
  | ExEff.HandlerCoercion (coerA, coerB) ->
    let ( (coerA2, coerA1), elabA ) = coer_elab_dirty state env coerA in
    let ( (coerB1, coerB2), elabB ) = coer_elab_dirty state env coerB in
    if ( (has_empty_dirt coerA1) && (has_empty_dirt coerA2) )
    (* Handler coercion - Case 1 *)
    then ( (ExEffTypes.Handler (coerA1, coerB1), ExEffTypes.Handler (coerA2, coerB2)), NoEff.NCoerArrow (elabA, elabB) )
    else (
      ( match coerB with 
        | ExEff.BangCoercion (tycoer, dirtcoer) ->
          let ( (t1', t2'), elab2 ) = coercion_elab_ty state env tycoer in
          if ( (not (has_empty_dirt coerA2) ) && (not (has_empty_dirt coerA2) ) )
          (* Handler coercion - Case 2 *)
          then ( (ExEffTypes.Handler (coerA1, coerB1), ExEffTypes.Handler (coerA2, coerB2)), NoEff.NCoerHandler (elabA, NoEff.NCoerComp elab2) ) 
          else (
            ( match coerA with
            | ExEff.BangCoercion (tycoerA, dirtcoerA) ->
              let ( (t2, t1), elab1 ) = coercion_elab_ty state env tycoerA in
              if (has_empty_dirt coerB1 && not (has_empty_dirt coerA1) && has_empty_dirt coerA2)
              (* Handler coercion - Case 3 *)
              then ( (ExEffTypes.Handler (coerA1, coerB1), ExEffTypes.Handler (coerA2, coerB2)), NoEff.NCoerHandToFun (elab1, NoEff.NCoerUnsafe elab2) )
              else (
                if ( has_empty_dirt coerA2 && not (has_empty_dirt coerA1) && not (has_empty_dirt coerB1) )
                (* Handler coercion - Case 4 *)
                then ( (ExEffTypes.Handler (coerA1, coerB1), ExEffTypes.Handler (coerA2, coerB2)), NoEff.NCoerHandToFun (elab1, elab2) )
                else failwith "Ill-typed handler coercion"
              ) 
            | _ -> failwith "Ill-typed handler coercion left side"
            )
          )
        | _ -> failwith "Ill-typed handler coercion right side"
      )
    )
  | ExEff.TyCoercionVar par -> 
    ( match (Assoc.lookup par env.ty_coer_types) with
    | Some xtype -> (xtype, NoEff.NCoerVar par)
    | None -> failwith "Coercion variable out of scope" )
  | ExEff.SequenceTyCoer (coer1, coer2) ->
    let ( (coer1ty1, coer1ty2), elab1 ) = coercion_elab_ty state env coer1 in
    let ( (coer2ty1, coer2ty2), elab2 ) = coercion_elab_ty state env coer2 in
    if (coer1ty2 = coer2ty1) 
    then ( (coer1ty1, coer2ty2), NoEff.NCoerTrans (elab1, elab2) )
    else (failwith "Ill-typed coercion sequencing")
  | ExEff.ApplyCoercion (name, coer_list) -> (* STIEN: What to elaborate to? Typing as in TypeChecker -> voeg applycoercion toe aan noeff *)
    let type_list = List.map (fun x -> fst (coercion_elab_ty state env x)) coer_list in
    let ty1s = List.map fst type_list in
    let ty2s = List.map snd type_list in
    let elab_list = List.map (fun x -> snd (coercion_elab_ty state env x)) coer_list in
    ( (ExEffTypes.Tuple ty1s, ExEffTypes.Tuple ty2s), NoEff.NCoerApply (name, elab_list) )
  | ExEff.TupleCoercion lst -> 
    let elabs = List.map (coercion_elab_ty state env) lst in
    let tylist = List.map fst elabs in
    let elablist = List.map snd elabs in
    ( (ExEffTypes.Tuple (List.map fst tylist), ExEffTypes.Tuple (List.map snd tylist)), NoEff.NCoerTuple elablist )
  | ExEff.LeftArrow c ->
    match c with
    | ExEff.ArrowCoercion (c1, c2) ->
      let (ty, _) = coercion_elab_ty state env c1 in
      let (_, elab) = coercion_elab_ty state env c in
      ( ty, NoEff.NCoerLeftArrow elab )
    | _ -> failwith "Ill-formed left arrow coercion"
  | ExEff.ForallTy (par, c) ->
    let ( ty, elab ) = coercion_elab_ty state env c in failwith "TODO" (* STIEN: Need the skeleton here, is fixed in Brecht's branch but not here yet *)
  | ExEff.ApplyTyCoer (c, t) -> failwith "TODO" (* STIEN: Same skeleton-note as above + NB: becomes NCoerInst in elaboration *)
  | ExEff.ForallDirt (par, c) ->
    let ( (ty1, ty2), elab ) = coercion_elab_ty state env c in
    ( (ExEffTypes.TySchemeDirt (par, ty1), ExEffTypes.TySchemeDirt (par, ty2)), elab )
  | ExEff.ApplyDirtCoer (c, d) ->
    let ( (ty1, ty2), elab ) = coercion_elab_ty state env c in
    ( match ty1 with
    | ExEffTypes.TySchemeDirt (par1, ty1) ->
      ( match ty2 with
      | ExEffTypes.TySchemeDirt (par2, ty2) -> 
        let subs1 = Substitution.add_dirt_substitution_e par1 d in
        let subs2 = Substitution.add_dirt_substitution_e par2 d in
        let ty1' = Substitution.apply_substitutions_to_type subs1 ty1 in
        let ty2' = Substitution.apply_substitutions_to_type subs2 ty2 in
        ( (ty1', ty2'), elab )  (* STIEN: not 100% sure *)
      | _ -> failwith "Ill-formed coercion dirt application" )
    | _ -> failwith "Ill-formed coercion dirt application" )
  | ExEff.PureCoercion c ->
    let ( ((ty1,_), (ty2,_)), elabc ) = coer_elab_dirty state env c in
    ( (ty1, ty2), NoEff.NCoerPure elabc )
  | ExEff.QualTyCoer ( (ty1, ty2), c ) ->
    let ( (tyc1, tyc2), elabc) = coercion_elab_ty state env c in
    let (_, ty1elab) = type_elab state env ty1 in
    let (_, ty2elab) = type_elab state env ty2 in
    ( ( ExEffTypes.QualTy ((ty1, ty2), tyc1), ExEffTypes.QualTy ((ty1, ty2), tyc2) ), NoEff.NCoerQual ( (ty1elab, ty2elab), elabc ) )
  | ExEff.QualDirtCoer ( dirts, c) ->
    let (tyc, elabc) = coercion_elab_ty state env c in
    ( (ExEffTypes.QualDirt (dirts, fst tyc), ExEffTypes.QualDirt (dirts, snd tyc) ), elabc)
  | ExEff.ApplyQualTyCoer (c1, c2) ->
    let (c2ty, c2elab) = coercion_elab_ty state env c2 in 
    ( match c1 with
    | ExEff.QualTyCoer (tys, ccty) ->
      if (c2ty = tys)
      then ( 
        let ( (ty1, ty2), ccelab ) = coercion_elab_ty state env ccty in 
        ( (ty1, ty2), NoEff.NCoerApp (ccelab, c2elab) ) )
      else (failwith "Ill-typed coercion application") 
    | _ -> failwith "Ill-typed coercion application")
  | ExEff.ApplyQualDirtCoer (c1, c2) -> 
    ( match c1 with 
    | ExEff.QualDirtCoer (ds, ccd) -> 
      if ( (coer_elab_dirt state env c2) = ds)
      then ( coercion_elab_ty state env ccd )
      else (failwith "Ill-typed coercion application")
    | _ -> failwith "Ill-typed coercion application" ) 
  | ExEff.ForallSkel (par, c) ->
    let ((ty1, ty2), elab) = coercion_elab_ty state env c in
    ( (ExEffTypes.TySchemeSkel (par, ty1), ExEffTypes.TySchemeSkel (par, ty2)), elab )
  | ExEff.ApplySkelCoer (c, skel) ->
    ( match c with
    | ExEff.ForallSkel (par, c) ->
      let ( (ty1, ty2), elab ) = coercion_elab_ty state env c in
      ( (ExEffTypes.TySchemeSkel (par, ty1), ExEffTypes.TySchemeSkel (par, ty2)), elab )
    | _ -> failwith "Ill-typed skeleton coercion application" )
 
and coer_elab_dirty state env (coer: ExEff.dirty_coercion) =
  match coer with
  | ExEff.BangCoercion (tcoer, dcoer) ->
    let ((ty1, ty2), tyelab) = coercion_elab_ty state env tcoer in
    let (d1, d2) = coer_elab_dirt state env dcoer in
    if (is_empty_dirt d1 && is_empty_dirt d2)
    then ( ((ty1, d1), (ty2,d2)), tyelab )
    else (
      if (is_empty_dirt d1)
      then ( ((ty1, d1), (ty2, d2)), NoEff.NCoerReturn tyelab)
      else (
        if ( not (is_empty_dirt d2) )
        then ( ((ty1, d1), (ty2, d2)), NoEff.NCoerComp tyelab)
        else failwith "Ill-typed bang coercion"
      )
    )
  | ExEff.RightArrow tycoer ->
    let ((ty1, ty2), tyelab) = coercion_elab_ty state env tycoer in
    ( match ty1 with 
      | ExEffTypes.Arrow (a,b) ->
        ( match ty2 with 
        | ExEffTypes.Arrow (c,d) ->
          ( (b, d), NoEff.NCoerRightArrow tyelab )
        | _ -> failwith "Ill-typed right arrow coercion"
        )
      | _ -> failwith "Ill-typed right arrow coercion"   
    ) 
  | ExEff.RightHandler tycoer ->
    let ((ty1, ty2), tyelab) = coercion_elab_ty state env tycoer in
    ( match ty1 with 
      | ExEffTypes.Handler (a,b) ->
        ( match ty2 with 
        | ExEffTypes.Handler (c,d) ->
          ( (b, d), NoEff.NCoerRightHandler tyelab )
        | _ -> failwith "Ill-typed right handler coercion"
        )
      | _ -> failwith "Ill-typed right handler coercion" 
    )
  | ExEff.LeftHandler tycoer ->
    let ((ty1, ty2), tyelab) = coercion_elab_ty state env tycoer in
    ( match ty1 with 
      | ExEffTypes.Handler (a,b) ->
        ( match ty2 with 
        | ExEffTypes.Handler (c,d) ->
          ( (c, a), NoEff.NCoerLeftHandler tyelab )
        | _ -> failwith "Ill-typed left handler coercion"
        )
      | _ -> failwith "Ill-typed left handler coercion"
    )
  | ExEff.SequenceDirtyCoer (c1, c2) ->
    let ( (ty11, ty12), c1elab ) = coer_elab_dirty state env c1 in
    let ( (ty21, ty22), c2elab ) = coer_elab_dirty state env c2 in
    if (ty12 = ty21) 
    then ( (ty11, ty22), NoEff.NCoerTrans (c1elab, c2elab) )
    else failwith "Ill-typed coercion sequence"

and coer_elab_dirt state env dcoer =
  match dcoer with
  | ExEff.ReflDirt dirt -> (dirt, dirt)
  | ExEff.DirtCoercionVar par -> 
  ( match (Assoc.lookup par env.dirt_coer_types) with
    | Some dirts -> dirts
    | None -> failwith "Dirt coercion variable out of scope" )
  | ExEff.Empty dirt -> (ExEffTypes.empty_dirt, dirt) 
  | ExEff.UnionDirt (set, dc) -> 
    let (d1, d2) = coer_elab_dirt state env dc in
    let d1' = {row= d1.row; effect_set= EffectSet.union set d1.effect_set} in
    let d2' = {row= d2.row; effect_set= EffectSet.union set d2.effect_set} in
    (d1', d2')
  | ExEff.SequenceDirtCoer (d1, d2) ->
    let (dirt11, dirt12) = coer_elab_dirt state env d1 in
    let (dirt21, dirt22) = coer_elab_dirt state env d2 in
    if (dirt12 = dirt21) 
    then (dirt11, dirt22) 
    else failwith "Ill-typed dirt coercion sequencing" 
  | ExEff.DirtCoercion dirty_coercion -> 
    let ((dirtyA,dirtyB), _) = coer_elab_dirty state env dirty_coercion in
    let (tyA,dA) = dirtyA in
    let (tyB,dB) = dirtyB in
    (dA,dB)

and get_effectset effects = get_effectset_temp EffectSet.empty effects

and get_effectset_temp set effects =
  match effects with
  | (((eff, _), abs)::es) -> get_effectset_temp (EffectSet.add eff set) es
  | [] -> set

and subst_ty_param tysub par ty =
  match ty with
  | ExEffTypes.TyParam x -> if (x = par) then tysub else ty
  | ExEffTypes.Apply (n, ls) -> ExEffTypes.Apply (n, List.map (subst_ty_param tysub par) ls)
  | ExEffTypes.Arrow (l, (rt, rd)) -> ExEffTypes.Arrow (subst_ty_param tysub par l, (subst_ty_param tysub par rt, rd))
  | ExEffTypes.Tuple ls -> ExEffTypes.Tuple (List.map (subst_ty_param tysub par) ls)
  | ExEffTypes.Handler ((lt, ld), (rt, rd)) -> ExEffTypes.Handler ((subst_ty_param tysub par lt, ld), (subst_ty_param tysub par rt, rd))
  | ExEffTypes.PrimTy p -> ExEffTypes.PrimTy p
  | ExEffTypes.QualTy ((ty1, ty2), ty3) ->
    ExEffTypes.QualTy ((subst_ty_param tysub par ty1, subst_ty_param tysub par ty2), 
        subst_ty_param tysub par ty3)
  | ExEffTypes.QualDirt (dirts, t) -> ExEffTypes.QualDirt (dirts, subst_ty_param tysub par t)
  | ExEffTypes.TySchemeTy (p, skel, t) -> ExEffTypes.TySchemeTy (p, skel, subst_ty_param tysub par t)
  | ExEffTypes.TySchemeDirt (p, t) -> ExEffTypes.TySchemeDirt (p, subst_ty_param tysub par t)
  | ExEffTypes.TySchemeSkel (p, t) -> ExEffTypes.TySchemeSkel (p, subst_ty_param tysub par t)
 
and comp_elab state env c = 
  match c with 
  | ExEff.Value value ->
    let (t, elab) = value_elab state env value in
    ((t, ExEffTypes.empty_dirt), elab)
  | ExEff.LetVal (value, (pat, _, comp)) -> 
    let (tyv, elabv) = value_elab state env value in
    let env' = extend_pattern_type env pat tyv in
    let (tyc, elabc) = comp_elab state env' comp in
    (tyc, NoEff.NLet (elabv, (pattern_elab pat, elabc)))
  | ExEff.LetRec (abs_list, comp) ->
    let rec extend_env env ls = 
      ( match ls with
        | [] -> env
        | ( (var, ty1, ty2, (p, comp)) :: rest ) ->
        let env' = TypeChecker.extend_var_types env var (ExEffTypes.Arrow (ty1, ty2)) in
        let env'' = extend_pattern_type env' p ty1 in
        extend_env env'' rest ) in
    let elab_letrec_abs ( (var, ty1, ty2, (p, compt)) ) =
            ( let (_, t1) = type_elab state env ty1 in
            let (_, t2) = dirty_elab state env ty2 in
            let (_, elabc) = comp_elab state (extend_env env [(var, ty1, ty2, (p, compt))]) compt in
            ( (var, t1, t2, (pattern_elab p, elabc)) ) ) in
    let (tycomp, elabcomp) = comp_elab state (extend_env env abs_list) comp in
    ( tycomp, NoEff.NLetRec (List.map (elab_letrec_abs) abs_list, elabcomp) )
  | ExEff.Match (value, abs_lst, loc) ->
    let (tyv, elabv) = value_elab state env value in
    let elab_abs vty cty (pat, comp) = 
            ( let env' = extend_pattern_type env pat vty in
              let (tyc, elabc) = comp_elab state env' comp in  
              if (tyc = cty) then (pattern_elab pat, elabc) else (typefail "Ill-typed match branch")) in
    ( if ( (List.length abs_lst) = 0)
    then ( failwith "TODO: Empty match statement" )
    else ( let ((p1,c1) :: _ ) = abs_lst in
           let (tyc, elabc) = comp_elab state env c1 in 
           (tyc, NoEff.NMatch (elabv, List.map (elab_abs tyv tyc) abs_lst, loc)) ) )
  | ExEff.Apply (v1, v2) -> 
    let (ty1, elab1) = value_elab state env v1 in
    ( match ty1 with
      | ExEffTypes.Arrow (t1, t2) -> 
        let (ty2, elab2) = value_elab state env v2 in
          if (ty2 = t1)
          then (t2, NoEff.NApplyTerm (elab1, elab2))
          else (failwith "Improper argument type")
      | _ -> failwith "Improper function type" )
  | ExEff.Handle (value, comp) -> 
    let ( (ctype, cdirt), elabc ) = comp_elab state env comp in 
    let ( vtype, velab ) = value_elab state env value in
    ( match vtype with
      | ExEffTypes.Handler ( (vty1, vdirt1), (vty2, vdirt2) ) ->
        if (vty1 = ctype && vdirt1 = cdirt) then (
          if (Types.is_empty_dirt cdirt)
          (* Handle - Case 1 *)
          then ( (vty2, vdirt2), NoEff.NApplyTerm (velab, elabc))
          else (
               if (Types.is_empty_dirt vdirt2)
               (* Handle - Case 2 *)
               then ( let (_, telab) = type_elab state env vty2 in
                 ( (vty2, vdirt2), 
                 NoEff.NCast (NoEff.NHandle (elabc, velab),
                 NoEff.NCoerUnsafe (NoEff.NCoerRefl (telab)))) )
               (* Handle - Case 3 *)
               else ( (vty2, vdirt2), NoEff.NHandle (elabc, velab))
               )
        )
        else failwith "Handler source type and handled computation type do not match"
      | _ -> failwith "Ill-typed handler" )
  | ExEff.Call ((eff, (ty1, ty2)), value, (p, ty, comp)) ->
    let (_, t1) = type_elab state env ty1 in
    let (_, t2) = type_elab state env ty2 in
    let (_, tt) = type_elab state env ty in
    let (vty, velab) = value_elab state env value in
    if (vty = ty1) 
    then (
      let env' = extend_pattern_type env p ty in
      let (cty, celab) = comp_elab state env' comp in
      ( cty, NoEff.NCall ((eff, (t1, t2)), velab, (pattern_elab p, tt, celab)) )
    )
    else failwith "Ill-typed call"
  | ExEff.Op ((eff, (ty1, ty2)), value) -> 
    let (_, t1) = type_elab state env ty1 in
    let (_, t2) = type_elab state env ty2 in
    let (vty, velab) = value_elab state env value in    
    if (vty = ty1)
    then ( ((ty2, ExEffTypes.empty_dirt), NoEff.NOp ((eff, (t1,t2)), velab)) )
    else (typefail "Ill-typed operation")
  | ExEff.Bind (c1, (p, c2)) ->
    let ((ty1, dirt1), elab1) = comp_elab state env c1 in
    let env' = extend_pattern_type env p ty1 in
    let ((ty2, dirt2), elab2) = comp_elab state env' c2 in
    if (ExEffTypes.is_empty_dirt dirt1 && ExEffTypes.is_empty_dirt dirt2)
    (* Bind - Case 1 *)
    then ( (ty2, dirt2), NoEff.NLet (elab1, (pattern_elab p, elab2)) )
    (* Bind - Case 2 *)
    else ( 
      if (dirt1 = dirt2) then ( (ty2, dirt2), NoEff.NBind (elab1, (pattern_elab p, elab2)) ) 
      else (typefail "Ill-typed bind") )
  | ExEff.CastComp (comp, coer) -> 
    let ( (t1, t2), elabc ) = coer_elab_dirty state env coer in
    let ( cty, coelab ) = comp_elab state env comp in
    if (cty = t1) 
    then ( (t2, NoEff.NCast (coelab, elabc) ) )
    else failwith "Ill-typed casting"

and has_empty_dirt ( (ty, dirt): ExEffTypes.target_dirty ) = is_empty_dirt dirt