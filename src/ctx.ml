type ty_scheme = (Core.variable, Type.ty) Common.assoc * Type.ty * Constr.t
type dirty_scheme = (Core.variable, Type.ty) Common.assoc * Type.dirty * Constr.t

type t = (Core.variable, ty_scheme option) Common.assoc


let empty = []

(** [refresh (ps,qs,rs) ty] replaces the polymorphic parameters [ps,qs,rs] in [ty] with fresh
    parameters. It returns the  *)
let refresh (ctx, ty, cnstrs) =
  let sbst = Type.refreshing_subst () in
  Common.assoc_map (Type.subst_ty sbst) ctx, Type.subst_ty sbst ty, Constr.subst_constraints sbst cnstrs

let lookup ctx x =
  match Common.lookup x ctx with
  | None -> None
  | Some None -> Some None
  | Some (Some sch) -> Some (Some (refresh sch))

let extend_ty ctx x =
    (x, None) :: ctx

(** [Type.free_params ctx] returns a list of all free type parameters in [ctx]. *)
let extend ctx x sch =
  (x, Some sch) :: ctx

let to_list ctx = ctx