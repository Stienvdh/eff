type ty_param = Ty_Param of int
type dirt_param = Dirt_Param of int
type region_param = Region_Param of int
type instance_param = Instance_Param of int
val fresh_ty_param : unit -> ty_param
val fresh_dirt_param : unit -> dirt_param
val fresh_region_param : unit -> region_param
val fresh_instance_param : unit -> instance_param
type params = (ty_param, dirt_param, region_param) Trio.t
type args = (ty, dirt_param, region_param) Trio.t
and ty =
    Apply of Common.tyname * args
  | Effect of Common.tyname * args * region_param
  | TyParam of ty_param
  | Basic of string
  | Tuple of ty list
  | Arrow of ty * dirty
  | Handler of handler_ty
and dirty = instance_param list * ty * dirt_param
and handler_ty = { value : ty; finally : ty; }
and dirt =
    DirtParam of dirt_param
  | DirtAtom of region_param * Common.opsym
  | DirtEmpty
and region = RegionParam of region_param | RegionAtom of instance
and instance = InstanceParam of instance_param | InstanceTop
val empty_dirt : dirt
type constraints =
    TypeConstraint of ty * ty * Common.position
  | DirtConstraint of dirt * dirt * Common.position
  | RegionConstraint of region * region * Common.position
type ty_scheme = params * ty * constraints list
val universal_ty : ty
val universal_dirty : ('a list * ty * dirt_param) * constraints list
val int_ty : ty
val string_ty : ty
val bool_ty : ty
val float_ty : ty
val unit_ty : ty
val empty_ty : ty
type substitution = {
  subst_ty : (ty_param * ty) list;
  subst_dirt : (dirt_param * dirt_param) list;
  subst_region : (region_param * region_param) list;
  subst_instance : (instance_param * instance_param option) list;
}
val subst_ty_scheme : substitution -> ty_scheme -> ty_scheme
val subst_constraints : substitution -> constraints list -> constraints list
val subst_dirty : substitution -> dirty -> dirty
val subst_ty : substitution -> ty -> ty
val identity_subst : substitution
val compose_subst : substitution -> substitution -> substitution
val free_params : ty_scheme -> params
val occurs_in_ty : ty_param -> ty -> bool
val fresh_ty : unit -> ty
val fresh_dirt : unit -> dirt
val fresh_dirty : unit -> 'a list * ty * dirt_param
val refreshing_subst :
  ty_param list * dirt_param list * region_param list ->
  (ty_param, dirt_param, region_param) Trio.t * substitution
val instance_refreshing_subst : instance_param list -> substitution
val refresh : ty_scheme -> ty_scheme
val variablize : ty -> ty
val disable_beautify : bool ref
val beautify :
  ?beautifier:'a ->
  (ty_param list * dirt_param list * region_param list) * ty *
  constraints list ->
  (ty_param list * dirt_param list * region_param list) * ty *
  constraints list
val beautify_dirty :
  (ty_param list * dirt_param list * region_param list) * ty *
  constraints list ->
  dirt_param ->
  ((ty_param list * dirt_param list * region_param list) * ty *
   constraints list) *
  dirt_param
val beautify2 :
  ty ->
  ty ->
  ((ty_param list * dirt_param list * region_param list) * ty) *
  ((ty_param list * dirt_param list * region_param list) * ty)