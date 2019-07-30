(** Syntax of the core language. *)

module Variable = Symbol.Make (Symbol.String)
module EffectMap = Map.Make (String)

type variable = Variable.t

type effect = CoreTypes.Effect.t * (Types.target_ty * Types.target_ty)

type e_pattern =
  | PEVar of variable
  | PEAs of e_pattern * variable
  | PETuple of e_pattern list
  | PERecord of (CoreTypes.field, e_pattern) Assoc.t
  | PEVariant of CoreTypes.label * e_pattern option
  | PEConst of Const.t
  | PENonbinding

(** Pure expressions *)
type e_expression =
  | EVar of variable
  | EBuiltIn of string * int
  | EConst of Const.t
  | ETuple of e_expression list
  | ERecord of (CoreTypes.field, e_expression) Assoc.t
  | EVariant of CoreTypes.label * e_expression option
  | ELambda of e_abstraction_with_ty
  | EEffect of effect
  | EHandler of e_handler
  | EBigLambdaSkel of CoreTypes.SkelParam.t * e_expression
  | EApplySkelExp of e_expression * Types.skeleton

(** Impure computations *)
and e_computation =
  | EValue of e_expression
  | ELetVal of e_pattern * e_expression * e_computation
  | EApply of e_expression * e_expression
  | EHandle of e_expression * e_computation
  | ECall of effect * e_expression * e_abstraction_with_ty
  | EBind of e_computation * e_abstraction
  | EMatch of e_expression * e_abstraction list
  | ELetRec of (variable * Types.skeleton * e_expression) list * e_computation

(** Handler definitions *)
and e_handler =
  { effect_clauses: (effect, e_abstraction2) Assoc.t
  ; value_clause: e_abstraction_with_ty }

(** Abstractions that take one argument. *)
and e_abstraction = (e_pattern * e_computation)

and e_abstraction_with_ty = (e_pattern * Types.skeleton * e_computation)

(** Abstractions that take two arguments. *)
and e_abstraction2 = (e_pattern * e_pattern * e_computation)