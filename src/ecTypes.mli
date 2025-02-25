(* -------------------------------------------------------------------- *)
open EcBigInt
open EcMaps
open EcSymbols
open EcUid
open EcIdent

(* -------------------------------------------------------------------- *)
(* FIXME: section: move me *)

type locality  = [`Declare | `Local | `Global ]
type is_local  =           [ `Local | `Global ]

val local_of_locality : locality -> is_local

(* -------------------------------------------------------------------- *)
type ty = private {
  ty_node : ty_node;
  ty_fv   : int Mid.t;
  ty_tag  : int;
}

and ty_node =
  | Tglob   of EcPath.mpath (* The tuple of global variable of the module *)
  | Tunivar of EcUid.uid
  | Tvar    of EcIdent.t
  | Ttuple  of ty list
  | Tconstr of EcPath.path * ty list
  | Tfun    of ty * ty

module Mty : Map.S with type key = ty
module Sty : Set.S with module M = Map.MakeBase(Mty)
module Hty : EcMaps.EHashtbl.S with type key = ty

type dom = ty list

val dump_ty : ty -> string

val ty_equal : ty -> ty -> bool
val ty_hash  : ty -> int

val tuni    : EcUid.uid -> ty
val tvar    : EcIdent.t -> ty
val ttuple  : ty list -> ty
val tconstr : EcPath.path -> ty list -> ty
val tfun    : ty -> ty -> ty
val tglob   : EcPath.mpath -> ty
val tpred   : ty -> ty

val ty_fv_and_tvar : ty -> int Mid.t

(* -------------------------------------------------------------------- *)
val tunit   : ty
val tbool   : ty
val tint    : ty
val txint   : ty
val treal   : ty
val tdistr  : ty -> ty
val toption : ty -> ty
val tcpred  : ty -> ty
val toarrow : ty list -> ty -> ty

val tytuple_flat : ty -> ty list
val tyfun_flat   : ty -> (dom * ty)

(* -------------------------------------------------------------------- *)
val is_tdistr : ty -> bool
val as_tdistr : ty -> ty option

(* -------------------------------------------------------------------- *)
exception FoundUnivar

val ty_check_uni : ty -> unit

(* -------------------------------------------------------------------- *)
type ty_subst = {
  ts_mp  : EcPath.smsubst;
  ts_u  : ty Muid.t;
  ts_v  : ty Mid.t;
}

val ty_subst_id    : ty_subst
val is_ty_subst_id : ty_subst -> bool

val ty_subst : ty_subst -> ty -> ty

module Tuni : sig
  val univars : ty -> Suid.t

  val subst1    : (uid * ty) -> ty_subst
  val subst     : ty Muid.t -> ty_subst
  val subst_dom : ty Muid.t -> dom -> dom
  val occurs    : uid -> ty -> bool
  val fv        : ty -> Suid.t
end

module Tvar : sig
  val subst1  : (EcIdent.t * ty) -> ty -> ty
  val subst   : ty Mid.t -> ty -> ty
  val init    : EcIdent.t list -> ty list -> ty Mid.t
  val fv      : ty -> Sid.t
end

(* -------------------------------------------------------------------- *)
(* [map f t] applies [f] on strict subterms of [t] (not recursive) *)
val ty_map : (ty -> ty) -> ty -> ty

(* [sub_exists f t] true if one of the strict-subterm of [t] valid [f] *)
val ty_sub_exists : (ty -> bool) -> ty -> bool

val ty_fold : ('a -> ty -> 'a) -> 'a -> ty -> 'a
val ty_iter : (ty -> unit) -> ty -> unit

(* -------------------------------------------------------------------- *)
val symbol_of_ty   : ty -> string
val fresh_id_of_ty : ty -> EcIdent.t

(* -------------------------------------------------------------------- *)
type lpattern =
  | LSymbol of (EcIdent.t * ty)
  | LTuple  of (EcIdent.t * ty) list
  | LRecord of EcPath.path * (EcIdent.t option * ty) list

val lp_equal : lpattern -> lpattern -> bool
val lp_hash  : lpattern -> int
val lp_bind  : lpattern -> (EcIdent.t * ty) list
val lp_ids   : lpattern -> EcIdent.t list
val lp_fv    : lpattern -> EcIdent.Sid.t

(* -------------------------------------------------------------------- *)
type ovariable = {
  ov_name : symbol option;
  ov_type : ty;
}
val ov_name  : ovariable -> symbol option
val ov_type  : ovariable -> ty
val ov_hash  : ovariable -> int
val ov_equal : ovariable -> ovariable -> bool

type variable = {
    v_name : symbol;   (* can be "_" *)
    v_type : ty;
  }
val v_name  : variable -> symbol
val v_type  : variable -> ty
val v_hash  : variable -> int
val v_equal : variable -> variable -> bool

val ovar_of_var: variable -> ovariable

(* -------------------------------------------------------------------- *)
type pvar_kind =
  | PVKglob
  | PVKloc

type prog_var = private
  | PVglob of EcPath.xpath
  | PVloc of EcSymbols.symbol

val pv_equal       : prog_var -> prog_var -> bool
val pv_compare     : prog_var -> prog_var -> int
val pv_ntr_compare : prog_var -> prog_var -> int

val pv_kind : prog_var -> pvar_kind

(* work only if the prog_var has been normalized *)
val pv_compare_p : prog_var -> prog_var -> int
val pv_hash    : prog_var -> int
val pv_fv      : prog_var -> int EcIdent.Mid.t
val is_loc     : prog_var -> bool
val is_glob    : prog_var -> bool

val get_loc     : prog_var -> EcSymbols.symbol
val get_glob    : prog_var -> EcPath.xpath

val symbol_of_pv   : prog_var -> symbol
val string_of_pvar : prog_var -> string
val name_of_pvar   : prog_var -> string

val pv_subst : (EcPath.xpath -> EcPath.xpath) -> prog_var -> prog_var

val pv_loc  : EcSymbols.symbol -> prog_var
val pv_glob : EcPath.xpath -> prog_var
val xp_glob : EcPath.xpath -> EcPath.xpath

val arg_symbol : symbol
val res_symbol : symbol
val pv_res  : prog_var
val pv_arg  : prog_var

(* -------------------------------------------------------------------- *)
type expr = private {
  e_node : expr_node;
  e_ty   : ty;
  e_fv   : int Mid.t;    (* module idents, locals *)
  e_tag  : int;
}

and expr_node =
  | Eint   of zint                         (* int. literal          *)
  | Elocal of EcIdent.t                    (* let-variables         *)
  | Evar   of prog_var                     (* module variable       *)
  | Eop    of EcPath.path * ty list        (* op apply to type args *)
  | Eapp   of expr * expr list             (* op. application       *)
  | Equant of equantif * ebindings * expr  (* fun/forall/exists     *)
  | Elet   of lpattern * expr * expr       (* let binding           *)
  | Etuple of expr list                    (* tuple constructor     *)
  | Eif    of expr * expr * expr           (* _ ? _ : _             *)
  | Ematch of expr * expr list * ty        (* match _ with _        *)
  | Eproj  of expr * int                   (* projection of a tuple *)

and equantif  = [ `ELambda | `EForall | `EExists ]
and ebinding  = EcIdent.t * ty
and ebindings = ebinding list

type closure = (EcIdent.t * ty) list * expr

(* -------------------------------------------------------------------- *)
val qt_equal : equantif -> equantif -> bool

(* -------------------------------------------------------------------- *)
val e_equal   : expr -> expr -> bool
val e_compare : expr -> expr -> int
val e_hash    : expr -> int
val e_fv      : expr -> int EcIdent.Mid.t
val e_ty      : expr -> ty

(* -------------------------------------------------------------------- *)
val e_tt       : expr
val e_int      : zint -> expr
val e_decimal  : zint * (int * zint) -> expr
val e_local    : EcIdent.t -> ty -> expr
val e_var      : prog_var -> ty -> expr
val e_op       : EcPath.path -> ty list -> ty -> expr
val e_app      : expr -> expr list -> ty -> expr
val e_let      : lpattern -> expr -> expr -> expr
val e_tuple    : expr list -> expr
val e_if       : expr -> expr -> expr -> expr
val e_match    : expr -> expr list -> ty -> expr
val e_lam      : (EcIdent.t * ty) list -> expr -> expr
val e_quantif  : equantif -> ebindings -> expr -> expr
val e_forall   : ebindings -> expr -> expr
val e_exists   : ebindings -> expr -> expr
val e_proj     : expr -> int -> ty -> expr
val e_none     : ty -> expr
val e_some     : expr -> expr
val e_oget     : expr -> ty -> expr

val e_proj_simpl : expr -> int -> ty -> expr

(* -------------------------------------------------------------------- *)
val is_local     : expr -> bool
val is_var       : expr -> bool
val is_tuple_var : expr -> bool

val destr_local     : expr -> EcIdent.t
val destr_var       : expr -> prog_var
val destr_app       : expr -> expr * expr list
val destr_tuple_var : expr -> prog_var list

(* -------------------------------------------------------------------- *)
val split_args : expr -> expr * expr list

(* -------------------------------------------------------------------- *)
val e_map :
     (ty   -> ty  ) (* 1-subtype op. *)
  -> (expr -> expr) (* 1-subexpr op. *)
  -> expr
  -> expr

val e_fold :
  ('state -> expr -> 'state) -> 'state -> expr -> 'state

val e_iter : (expr -> unit) -> expr -> unit

(* -------------------------------------------------------------------- *)
type e_subst = {
  es_freshen : bool; (* true means realloc local *)
  es_ty      : ty_subst;
  es_loc     : expr Mid.t;
}

val e_subst_id : e_subst

val is_e_subst_id : e_subst -> bool

val e_subst_init :
     bool
  -> ty_subst
  -> expr Mid.t
  -> e_subst

val add_local  : e_subst -> EcIdent.t * ty -> e_subst * (EcIdent.t * ty)
val add_locals : e_subst -> (EcIdent.t * ty) list -> e_subst * (EcIdent.t * ty) list

val e_subst_closure : e_subst -> closure -> closure
val e_subst : e_subst -> expr -> expr

(* val e_mapty : (ty -> ty) -> expr -> expr *)

(* val e_uni   : (uid -> ty option) -> expr -> expr *)
