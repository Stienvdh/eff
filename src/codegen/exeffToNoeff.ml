open NoEffSyntax
open Types
open Typed

module NoEff = NoEffSyntax
module ExEffTypes = Types
module ExEff = Typed
module EffectSet = Set.Make (CoreTypes.Effect)

type effect_set = EffectSet.t

let rec type_elab ty =
  match ty with
  | ExEffTypes.TyParam x -> NoEff.NTyParam x
  | ExEffTypes.Apply (name, lst) -> NoEff.NTyApply (name, List.map type_elab lst)
  | ExEffTypes.Arrow (ty, dirty) -> NoEff.NTyArrow (type_elab ty, dirty_elab dirty)
  | ExEffTypes.Handler ((type1, dirt1), dirty) ->
    if (EffectSet.is_empty (dirt1.effect_set) && (dirt1.row = ExEffTypes.EmptyRow))
    then NoEff.NTyArrow ( (type_elab type1), (dirty_elab dirty) )
    else NoEff.NTyHandler ( (dirty_elab (type1, dirt1)), (dirty_elab dirty) )
  | ExEffTypes.Tuple tys -> NoEff.NTyTuple (List.map type_elab tys)
  | ExEffTypes.QualTy ( (t1, t2), ty) ->
    NoEff.NTyQual ( (type_elab t1, type_elab t2), type_elab ty)
  | ExEffTypes.QualDirt (_, ty) -> type_elab ty
  | ExEffTypes.TySchemeTy (par, skel, ty) -> NoEff.NTyForall (par, type_elab ty)
  | ExEffTypes.TySchemeDirt (par, ty) -> type_elab ty
  | ExEffTypes.TySchemeSkel (par, ty) -> type_elab ty
  | ExEffTypes.PrimTy ty ->
    match ty with
    | ExEffTypes.IntTy -> NoEff.NTyPrim NInt
    | ExEffTypes.BoolTy -> NoEff.NTyPrim NBool
    | ExEffTypes.StringTy -> NoEff.NTyPrim NString
    | ExEffTypes.FloatTy -> NoEff.NTyPrim NFloat

and dirty_elab (ty, dirt) =
  if ( (EffectSet.is_empty dirt.effect_set) && (dirt.row = ExEffTypes.EmptyRow) )
  then type_elab ty
  else NoEff.NTyComp (type_elab ty)

and pattern_elab p =
  match p with
  | PVar x -> NVar x
  | PAs (p, x) -> NAs (pattern_elab p, x)
  | PTuple ps -> NTuple (List.map pattern_elab ps)
  | PConst c -> NConst c
  | PNonbinding -> NNonBinding

and value_elab v =
  match v with
  | ExEff.Var x -> NoEff.NVar x
  | ExEff.BuiltIn (s, i) -> NoEff.NBuiltIn (s, i)
  | ExEff.Const c -> NoEff.NConst c
  | ExEff.Tuple vs -> NoEff.NTuple (List.map value_elab vs)
  | ExEff.Lambda (p, t, c) -> NoEff.NFun (pattern_elab p, type_elab t, comp_elab c)
  | ExEff.Effect (e, (t1, t2)) -> NoEff.NEffect (e, (type_elab t1, type_elab t2))
  (* STIEN This does not correspond the paper yet *)
  | ExEff.Handler h ->
    let (p, t, c) = h.value_clause in
    let elab_effect_clause ((eff, (ty1, ty2)), (p1, p2, comp)) = ((eff, (type_elab ty1, type_elab ty2)), (pattern_elab p1, pattern_elab p2, comp_elab comp)) in
    NHandler {return_clause= (pattern_elab p, type_elab t, comp_elab c);
	effect_clauses= (Assoc.map_of_list elab_effect_clause (Assoc.to_list h.effect_clauses))}
  | ExEff.BigLambdaTy (par, skel, value) -> NoEff.NBigLambdaTy (par, value_elab value)
  | ExEff.BigLambdaDirt (par, value) -> value_elab value
  | ExEff.BigLambdaSkel (par, value) -> value_elab value
  | ExEff.CastExp (value, coer) -> NoEff.NCast (value_elab value, coercion_elab_ty coer)
  | ExEff.ApplyTyExp (value, ty) -> NoEff.NTyAppl (value_elab value, type_elab ty)
  | ExEff.LambdaTyCoerVar (par, (ty1, ty2), value) -> 
    NoEff.NBigLambdaCoer (par, (type_elab ty1, type_elab ty2), value_elab value)
  | ExEff.LambdaDirtCoerVar (_, _, value) -> value_elab value
  | ExEff.ApplyDirtExp (value, dirt) -> failwith "STIEN: Need dirt instantiation for this"
  | ExEff.ApplySkelExp (value, skel) -> value_elab value
  | ExEff.ApplyTyCoercion (value, coer) -> NoEff.NApplyCoer (value_elab value, coercion_elab_ty coer)
  | ExEff.ApplyDirtCoercion (value, _) -> value_elab value

and coercion_elab_ty = failwith "TODO"

and coercion_elab_dirty = failwith "TODO"
 
and comp_elab c = 
  match c with 
  | ExEff.Value value -> value_elab value
  | ExEff.LetVal (value, (pat, ty, comp)) -> NLet (value_elab value, (pattern_elab pat, type_elab ty, comp_elab comp))
  | ExEff.LetRec (abs_list, comp) ->
    let letrec_elab (var, ty1, ty2, (p, cc)) = (var, type_elab ty1, dirty_elab ty2, (pattern_elab p, comp_elab cc)) in
    NoEff.NLetRec (List.map letrec_elab abs_list, comp_elab comp)
  | ExEff.Match (value, abs_lst, loc) ->
    let elab_abs (p, c) = (pattern_elab p, comp_elab c) in
    NoEff.NMatch (value_elab value, List.map elab_abs abs_lst, loc)
  | ExEff.Apply (v1, v2) -> NoEff.NApplyTerm (value_elab v1, value_elab v2)
  (* STIEN: This does also not follow the paper yet *)
  | ExEff.Handle (value, comp) -> NoEff.NHandle (comp_elab comp, value_elab value)
  | ExEff.Call ((eff, (ty1, ty2)), value, (p, ty, comp)) ->
    NoEff.NCall ((eff, (type_elab ty1, type_elab ty2)), value_elab value, (pattern_elab p, type_elab ty, comp_elab comp))
  | ExEff.Op ((eff, (ty1, ty2)), value) -> NoEff.NOp ((eff, (type_elab ty1, type_elab ty2)), value_elab value)
  (* STIEN: This does not correspond to the paper either *)
  | ExEff.Bind (c1, (p, c2)) ->
    NoEff.NBind (comp_elab c1, (pattern_elab p, comp_elab c2))
  | ExEff.CastComp (comp, coer) -> NoEff.NCast (comp_elab comp, coercion_elab_dirty coer)
  | ExEff.CastComp_ty (comp, coer) -> NoEff.NCast (comp_elab comp, coercion_elab_ty coer)
  | ExEff.CastComp_dirt (comp, _) -> comp_elab comp
