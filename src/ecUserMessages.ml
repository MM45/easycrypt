(* -------------------------------------------------------------------- *)
open EcSymbols
open EcUid
open EcPath
open EcUtils
open EcTypes
open EcEnv

(* -------------------------------------------------------------------- *)
type pp_options = {
  ppo_prpo : EcPrinting.prpo_display;
}

let ppo : (pp_options option) ref = ref None

let set_ppo (newppo : pp_options) =
  ppo := Some newppo

(* -------------------------------------------------------------------- *)
module TypingError : sig
  open EcTyping

  val pp_fxerror         : env -> Format.formatter -> fxerror -> unit
  val pp_tyerror         : env -> Format.formatter -> tyerror -> unit
  val pp_cnv_failure     : env -> Format.formatter -> tymod_cnv_failure -> unit
  val pp_mismatch_funsig : env -> Format.formatter -> mismatch_funsig -> unit
  val pp_modappl_error   : env -> Format.formatter -> modapp_error -> unit
  val pp_restr_error     : env -> Format.formatter -> restriction_error -> unit
end = struct
  open EcTyping

  let pp_mismatch_funsig env0 fmt error =
    let ppe0 = EcPrinting.PPEnv.ofenv env0 in

    let msg x = Format.fprintf fmt x in

    let pp_type fmt ty = EcPrinting.pp_type ppe0 fmt ty in

    let pp_cost ppe fmt c =
        EcPrinting.pp_form ppe fmt c in

    let pp_self ppe mode fmt (iself,oself) =
      Format.fprintf fmt
        "@[<v>self cost:@;  @[%a@]@; cannot be shown \
         to be %s:@;  @[%a@]@]"
        (pp_cost ppe) iself
        (match mode with `Eq -> "equal to" | `Sub -> "upper-bounded by")
        (pp_cost ppe) oself in

    let pp_diff ppe mode fmt (f,(ic,oc)) =
      Format.fprintf fmt
        "@[<v>the maximal number of calls to %a:@;  @[%a@]@; cannot be shown \
         to be %s:@;  @[%a@]@]"
        (EcPrinting.pp_funname ppe) f
        (pp_cost ppe) ic
        (match mode with `Eq -> "equal to" | `Sub -> "upper-bounded by")
        (pp_cost ppe) oc in

    match error with
    | MF_targs (ex, got) ->
        msg "its argument has type %a instead of %a"
          pp_type got pp_type ex

    | MF_tres (ex, got) ->
        msg "its return type is %a instead of %a"
          pp_type got pp_type ex

    | MF_restr (env, `Sub sx) ->
        let ppe = EcPrinting.PPEnv.ofenv env in
        msg "the function is not allowed to use %a"
          (EcPrinting.pp_list " or@ " (EcPrinting.pp_funname ppe))
          (Sx.ntr_elements sx)

    | MF_restr (env, `Eq (ex, got)) ->
        let ppe = EcPrinting.PPEnv.ofenv env in
        let allowed = Sx.diff ex got in
        let has_allowed = not (Sx.is_empty allowed) in
        let notallowed  = Sx.diff got ex in

        if has_allowed then
          msg "the function should be allowed to use %a"
            (EcPrinting.pp_list " or@ " (EcPrinting.pp_funname ppe))
            (Sx.ntr_elements allowed);
        if not (Sx.is_empty notallowed) then
          msg "%sthe function is not allowed to use %a"
            (if has_allowed then ",@ " else "")
            (EcPrinting.pp_list " or@ " (EcPrinting.pp_funname ppe))
            (Sx.ntr_elements notallowed)

    | MF_compl (env, `Sub (self,diffs)) ->
      let ppe = EcPrinting.PPEnv.ofenv env in
      let pp_self_sep fmt = function
        | None -> ()
        | Some self ->
          if Mx.is_empty diffs then
            pp_self ppe `Sub fmt self
          else
            Format.fprintf fmt "%a@;" (pp_self ppe `Sub) self in
      Format.fprintf fmt "@[<v>%a%a@]"
        pp_self_sep self
        (EcPrinting.pp_list "@;" (pp_diff ppe `Sub))
        (Mx.bindings diffs)

    | MF_compl (env, `Eq (self,diffs)) ->
      let ppe = EcPrinting.PPEnv.ofenv env in
      let pp_self_sep fmt = function
        | None -> ()
        | Some self ->
          if Mx.is_empty diffs then
            pp_self ppe `Sub fmt self
          else
            Format.fprintf fmt "%a@;" (pp_self ppe `Eq) self in

      Format.fprintf fmt "@[<v>%a%a@]"
        pp_self_sep self
        (EcPrinting.pp_list "@;" (pp_diff ppe `Eq))
        (Mx.bindings diffs)

    | MF_unbounded ->
      msg "the function does not satisfy the required complexity restriction \
          (at least, it cannot be infered from its type)"

  let pp_restr_err_aux env fmt error =
    let msg x = Format.fprintf fmt x in

    let ppe = EcPrinting.PPEnv.ofenv env in
    let pp_v fmt xp =
      Format.fprintf fmt "%a"
        (EcPrinting.pp_pv ppe) (pv_glob xp) in
    let pp_m fmt m =
      Format.fprintf fmt "%a"
        (EcPrinting.pp_topmod ppe) m in

    match error with
    | `Sub (xs,ms) when Sm.is_empty ms ->
      msg "is not allowed to use the variable(s)@ %a"
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xs)

    | `Sub (xs,ms) when Sx.is_empty xs ->
      msg "is not allowed to use the modules(s)@ %a"
        (EcPrinting.pp_list " and@ " pp_m)
        (Sm.ntr_elements ms)

    | `Sub (xs,ms) ->
      msg "is not allowed to use the variable(s)@ %a@ \
           and the module(s)@ %a"
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xs)
        (EcPrinting.pp_list " and@ " pp_m) (Sm.ntr_elements ms)

    | `RevSub None ->
      msg "must be unrestricted"

    | `RevSub (Some (xs,ms)) when Sm.is_empty ms ->
      msg "must be allowed to use the variable(s)@ %a"
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xs)

    | `RevSub (Some (xs,ms)) when Sx.is_empty xs ->
      msg "must be allowed to use the modules(s)@ %a"
        (EcPrinting.pp_list " and@ " pp_m)
        (Sm.ntr_elements ms)

    | `RevSub (Some (xs,ms)) ->
      msg "must be allowed to use the variable(s)@ %a@ \
           and the module(s)@ %a"
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xs)
        (EcPrinting.pp_list " and@ " pp_m) (Sm.ntr_elements ms)

    | `Eq (xl,ml,xr,mr) when Sm.is_empty ml && Sm.is_empty mr ->
      msg "the memory restriction@ %a@ \
           is not compatible with the memory restriction@ %a"
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xl)
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xr)

    | `Eq (xl,ml,xr,mr) when Sx.is_empty xl && Sx.is_empty xr ->
      msg "the memory module restriction@ %a@ \
           is not compatible with the memory module restriction@ %a"
        (EcPrinting.pp_list " and@ " pp_m)
        (Sm.ntr_elements ml)
        (EcPrinting.pp_list " and@ " pp_m)
        (Sm.ntr_elements mr)

    | `Eq (xl,ml,xr,mr) ->
      msg "the memory restriction@ %a@ %a@ \
           is not compatible with the memory restriction@ %a@ %a"
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xl)
        (EcPrinting.pp_list " and@ " pp_m) (Sm.ntr_elements ml)
        (EcPrinting.pp_list " and@ " pp_v) (Sx.ntr_elements xr)
        (EcPrinting.pp_list " and@ " pp_m) (Sm.ntr_elements mr)

    | `FunCanCallUnboundedOracle (fn,o) ->
      msg "proof obligation cannot be met, because procedure \
           %s can call oracle %a, which has an \
           unbounded self complexity.@."
        fn (EcPrinting.pp_funname ppe) o

  let rec pp_cnv_failure env fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | E_TyModCnv_ParamCountMismatch ->
        msg "not the same number of module arguments"

    | E_TyModCnv_ParamTypeMismatch x ->
        msg "the module argument `%s' does not have the expected type"
          (EcIdent.name x)

    | E_TyModCnv_MissingComp x ->
        msg "procedure `%s' is missing" x

    | E_TyModCnv_MismatchRestr (x,restr_err) ->
      msg "the module `%s' %a"
        x (pp_restr_err_aux env) restr_err

    | E_TyModCnv_MismatchFunSig (x,err) ->
      msg "@[<hov 2>procedure `%s' is not compatible:@ %a@]"
        x (pp_mismatch_funsig env) err

    | E_TyModCnv_SubTypeArg(x,t1,t2,err) ->
      let ppe = EcPrinting.PPEnv.ofenv env in
      msg "@[<v>for argument %s:@   %a is not a subtype of %a because@   %a@]"
        (EcIdent.name x)
        (EcPrinting.pp_modtype ppe) t1
        (EcPrinting.pp_modtype ppe) t2
        (pp_cnv_failure env) err

  let pp_modappl_error env fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | MAE_WrongArgCount (ex,got)->
        msg "wrong number of arguments (expected %i, got %i)" ex got

    | MAE_InvalidArgType (mp,error) ->
        let ppe = EcPrinting.PPEnv.ofenv env in
        msg "argument %a does not match required interface, %a"
          (EcPrinting.pp_topmod ppe) mp
          (pp_cnv_failure env) error

    | MAE_AccesSubModFunctor ->
        msg "cannot access a sub-module of a partially applied functor"

  let pp_fxerror _env fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | FXE_EmptyMatch ->
        msg "this pattern matching has no branches"

    | FXE_MatchParamsMixed ->
        msg "this pattern matching matches on different parameters"

    | FXE_MatchParamsDup ->
        msg "this pattern matching matches a parameter twice"

    | FXE_MatchParamsUnk ->
        msg "this pattern matching matches an unbound parameter"

    | FXE_MatchNonLinear ->
        msg "this pattern is non-linear"

    | FXE_MatchDupBranches ->
        msg "this pattern matching contains duplicated branches"

    | FXE_MatchPartial ->
        msg "this pattern matching is non-exhaustive"

    | FXE_CtorUnk ->
        msg "unknown constructor name"

    | FXE_CtorAmbiguous ->
        msg "ambiguous constructor name"

    | FXE_CtorInvalidArity (cname, i, j) ->
        msg
          "the constructor %s expects %d argument(s) (%d argument(s) given)"
          cname i j

    | FXE_SynCheckFailure ->
        msg "syntactic termination check failure"

  let pp_tyerror env1 fmt error =
    let env   = EcPrinting.PPEnv.ofenv env1 in
    let msg x = Format.fprintf fmt x in
    let pp_type fmt ty = EcPrinting.pp_type env fmt ty in

    match error with
    | UniVarNotAllowed ->
        msg "type place holders not allowed"

    | FreeTypeVariables ->
        msg "this expression contains free type variables"

    | TypeVarNotAllowed ->
        msg "type variables not allowed"

    | NoConcreteAnonParams ->
        msg "parameters to concrete procedures must be named"

    | OnlyMonoTypeAllowed s ->
        msg "%s, %s%a"
          "only monomorphic types are allowed"
          "you may have to add type annotations"
          (fun fmt -> oiter (Format.fprintf fmt " on %s")) s

    | UnboundTypeParameter x ->
        msg "unbound type parameter: %s" x

    | UnknownTypeName qs ->
        msg "unknown type name: %a" pp_qsymbol qs

    | UnknownTypeClass qs ->
        msg "unknown type class: %a" pp_qsymbol qs

    | UnknownRecFieldName qs ->
        msg "unknown (record) field name: %a" pp_qsymbol qs

    | UnknownInstrMetaVar x ->
        msg "unknown instruction meta-variable: %a" pp_symbol x

    | UnknownMetaVar x ->
        msg "unknown meta-variable: %a" pp_symbol x

    | DuplicatedRecFieldName qs ->
        msg "duplicated (record) field name: %s" qs

    | MissingRecField qs ->
        msg "missing (record) field: %s" qs

    | MixingRecFields (p1, p2) ->
        msg "mixing (record) fields from different record types: %a / %a"
          (EcPrinting.pp_tyname env) p1
          (EcPrinting.pp_tyname env) p2

    | UnknownProj qs ->
        msg "unknown record projection: %a" pp_qsymbol qs

    | AmbiguousProj qs ->
        msg "ambiguous record projection: %a" pp_qsymbol qs

    | AmbiguousProji (i, ty) ->
      let i = max (i + 1) 2 in
      msg "type %a should be a tuple of at least %i elements" pp_type ty i

    | InvalidTypeAppl (name, _, _) ->
        msg "invalid type application: %a" pp_qsymbol name

    | DuplicatedTyVar ->
        msg "a type variable appear at least twice"

    | DuplicatedLocal name ->
        msg "duplicated local/parameters name: `%s'" name

    | DuplicatedField name ->
        msg "duplicated field name: `%s'" name

    | NonLinearPattern ->
        msg "non-linear pattern matching"

    | LvNonLinear ->
        msg "This left-value is contains twice the same variable"

    | NonUnitFunWithoutReturn ->
        msg "This function must return a value"

    | TypeMismatch ((ty1, ty2), _) ->
        msg "This expression has type@\n";
        msg "  @[<hov 2> %a@]@\n@\n" pp_type ty2;
        msg "but is expected to have type@\n";
        msg "  @[<hov 2> %a@]" pp_type ty1

    | TypeClassMismatch ->
        msg "Type-class unification failure"

    | TypeModMismatch(mp, mt, err) ->
        msg "the module %a does not have the module type %a:@\n"
          (EcPrinting.pp_topmod env) mp
          (EcPrinting.pp_modtype env) mt;
        msg "  @[<hov 2>%t@]" (fun fmt -> pp_cnv_failure env1 fmt err)

    | NotAFunction ->
        msg "the expression is not a function, it can not be applied"

    | NotAnInductive ->
        msg "the expression does not have an inductive type"

    | AbbrevLowArgs ->
        msg "this abbreviation is not applied enough"

    | UnknownProgVar (p, mem) ->
        msg "unknown program variable (in %a): `%a'"
          (EcPrinting.pp_mem env) mem pp_qsymbol p

    | UnknownVarOrOp (name, []) ->
        msg "unknown variable or constant: `%a'" pp_qsymbol name

    | UnknownVarOrOp (name, tys) ->
        msg "no matching operator, named `%a', " pp_qsymbol name;
        msg "for the following parameters' type:@\n";
        List.iteri (fun i ty -> msg "  [%d]: @[%a@]@\n" (i+1) pp_type ty) tys

    | MultipleOpMatch (name, tys, matches) -> begin
        let uvars = List.map EcTypes.Tuni.univars tys in
        let uvars = List.fold_left Suid.union Suid.empty uvars in

        begin match tys with
        | [] ->
            msg
              "more that one variable or constant matches `%a'@\n"
              pp_qsymbol name

        | _  ->
            let pp_argty i ty = msg "  [%d]: @[%a@]@\n" (i+1) pp_type ty in
            msg "more than one operator, named `%a', matches.@\n@\n" pp_qsymbol name;
            msg "operator parameters' type were:@\n";
            List.iteri pp_argty tys
        end;
        msg "@\n";

        let pp_op fmt ((op, inst), subue) =
          let uidmap = EcUnify.UniEnv.assubst subue in
          let inst = Tuni.subst_dom uidmap inst in

          begin match inst with
          | [] ->
              Format.fprintf fmt "%a"
                EcPrinting.pp_path op
          | _  ->
            Format.fprintf fmt "%a <%a>"
              EcPrinting.pp_path op
              (EcPrinting.pp_list ",@ " pp_type) inst
          end;

          let myuvars = List.map EcTypes.Tuni.univars inst in
          let myuvars = List.fold_left Suid.union uvars myuvars in
          let myuvars = Suid.elements myuvars in

          let uidmap = EcUnify.UniEnv.assubst subue in
          let tysubst = ty_subst (Tuni.subst uidmap) in
          let myuvars = List.pmap
            (fun uid ->
              match tysubst (tuni uid) with
              | { ty_node = Tunivar uid' } when uid = uid' -> None
              | ty -> Some (uid, ty))
            myuvars
          in

          if not (List.is_empty myuvars) then begin
            Format.fprintf fmt "@\n    where@\n";
            List.iter (fun (uid, uidty) ->
              Format.fprintf fmt "      %a = %a@\n"
                (EcPrinting.pp_tyunivar env) uid pp_type uidty)
              myuvars
          end
        in

        msg "the list of matching objects follows:@\n";
        List.iter (fun (m, ue) ->
          let (title, Cb (x, pp)) =
            match m with
            | `Var pv ->
               ("prog. variable", Cb (pv, EcPrinting.pp_pv env))
            | `Lc id ->
               ("local variable", Cb (id, EcPrinting.pp_local env))
            | `Proj (pv, _) ->
               ("variable proj.", Cb (pv, EcPrinting.pp_pv env))
            | `Op op ->
               ("operator", Cb ((op, ue), pp_op))
          in msg "  [%s]: %a@\n" title pp x) matches
    end

    | UnknownModName name ->
        msg "unknown module: %a" pp_qsymbol name

    | UnknownTyModName name ->
        msg "unknown type name: %a" pp_qsymbol name

    | UnknownFunName name ->
        msg "unknown procedure: %a" pp_qsymbol name

    | UnknownModVar x ->
        msg "unknown module-level variable: %a" pp_qsymbol x

    | UnknownMemName m ->
        msg "unknown memory: %s" m

    | InvalidFunAppl FAE_WrongArgCount ->
        msg "invalid function application: wrong number of arguments"

    | InvalidModAppl err ->
        msg "invalid module application:@ %a" (pp_modappl_error env1) err

    | InvalidModType MTE_IncludeFunctor ->
        msg "cannot include functors"

    | InvalidModType MTE_InnerFunctor ->
        msg "functors must be top-level modules"

    | InvalidModType (MTE_DupProcName x) ->
        msg "duplicated var/proc name in module expression: `%s'" x

    | InvalidModSig (MTS_DupProcName x) ->
        msg "duplicated proc. name in signature: `%s'" x

    | InvalidModSig (MTS_DupArgName (f, x)) ->
        msg "duplicated proc. arg. name in signature: `%s.%s'" f x

    | InvalidMem (name, MAE_IsConcrete) ->
        msg "the memory %s must be abstract" name

    | InvalidMatch fxerror ->
        pp_fxerror env1 fmt fxerror

    | InvalidFilter (FE_InvalidIndex i) ->
        msg "invalid filter index: %d" i

    | InvalidFilter FE_NoMatch ->
        msg "invalid filter pattern (no match)"

    | FunNotInModParam name ->
        msg "the function %a is not provided by a module parameter. \
             Maybe you forgot a #?"
          pp_qsymbol name

    | FunNotInSignature name ->
      msg "the function %a is not in the signature"
          pp_symbol name

    | InvalidVar ->
        msg "cannot have applied functors in a variable path"

    | NoActiveMemory ->
        msg "no active memory at this point"

    | PatternNotAllowed ->
        msg "pattern not allowed here"

    | MemNotAllowed ->
        msg "memory not allowed here"

    | UnknownScope sc ->
        msg "unknown scope: `%a'" pp_qsymbol sc

    | NoWP ->
        msg "cannot compute weakest precondition"

    | FilterMatchFailure ->
        msg "filter pattern does not match"

    | MissingMemType ->
        msg "memory type missing"

    | SchemaVariableReBinded id ->
        msg "the schema variable %a has been rebinded"
            EcIdent.pp_ident id

    | SchemaMemBinderBelowCost ->
      msg "predicates binding memories are not allowed below a cost statement \
           in a schema"

    | ModuleNotAbstract m ->
      msg "the module %s is not abstract" m

    | ProcedureUnbounded (m,f) ->
      msg "%s.%s's complexity is unbounded" m f

    | LvMapOnNonAssign ->
        msg "map-style left-value cannot be used with assignments"

    | NoDefaultMemRestr ->
      msg "no default sign for memory restriction. Use '+' or '-', or \
           set the %s pragma to retrieve the old behaviour"
        EcGState.old_mem_restr

    | ProcAssign q ->
        msg "the right-hand side of this assignment cannot be typed as an expression;
             if you meant to call procedure `%a', assign its result using `<@' rather than `<-'"
            pp_qsymbol q

  let pp_restr_error env fmt (w, e) =
    let ppe = EcPrinting.PPEnv.ofenv env in

    let pp_restriction_who fmt = function
      | RW_mod mp ->
          Format.fprintf fmt "the module %a" pp_m mp

      | RW_fun xp ->
          Format.fprintf fmt "the procedure %a" (EcPrinting.pp_funname ppe) xp in

    Format.fprintf fmt "%a %a" pp_restriction_who w (pp_restr_err_aux env) e
end

(* -------------------------------------------------------------------- *)
module InductiveError : sig
  open EcHiInductive

  val pp_rcerror : env -> Format.formatter -> rcerror -> unit
  val pp_dterror : env -> Format.formatter -> dterror -> unit
  val pp_fxerror : env -> Format.formatter -> fxerror -> unit
end = struct
  open EcHiInductive
  open TypingError

  let pp_rcerror env fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | RCE_TypeError ee ->
        pp_tyerror env fmt ee

    | RCE_DuplicatedField name ->
        msg "duplicated field: `%s'" name

    | RCE_InvalidFieldType (name, ee) ->
        msg "invalid field type: `%s`: %a'" name (pp_tyerror env) ee

    | RCE_Empty ->
        msg "this record type is empty"

  let pp_dterror env fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | DTE_TypeError ee ->
        pp_tyerror env fmt ee

    | DTE_DuplicatedCtor name ->
        msg "duplicated constructor name: `%s'" name

    | DTE_InvalidCTorType (name, ee) ->
        msg "invalid constructor type: `%s`: %a'"
          name (pp_tyerror env) ee

    | DTE_NonPositive ->
        msg "the datatype does not respect the positivity condition"

    | DTE_Empty ->
        msg "the datatype may be empty"

  let pp_fxerror env fmt error =
    match error with
    | FXLowError ee ->
        pp_tyerror env fmt ee

    | FXError ee ->
        pp_fxerror env fmt ee
end

(* -------------------------------------------------------------------- *)
module PredError : sig
  open EcHiPredicates

  val pp_tperror : env -> Format.formatter -> tperror -> unit
end = struct
  open EcHiPredicates

  let pp_tperror (env : env) fmt = function
  | TPE_Typing e ->
      TypingError.pp_tyerror env fmt e
  | TPE_TyNotClosed ->
      Format.fprintf fmt "this predicate type contains free type variables"
  | TPE_DuplicatedConstr x ->
      Format.fprintf fmt "duplicated constructor name: `%s'" x
end

(* -------------------------------------------------------------------- *)
module NotationsError : sig
  open EcHiNotations

  val pp_nterror : env -> Format.formatter -> nterror -> unit
end = struct
  open EcHiNotations

  let pp_nterror (env : env) fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | NTE_Typing e ->
       TypingError.pp_tyerror env fmt e
    | NTE_TyNotClosed ->
       msg "this notation type contains free type variables"
    | NTE_DupIdent ->
       msg "an ident is bound several time"
    | NTE_UnknownBinder x ->
       msg "unknown binder: `%s'" x
    | NTE_AbbrevIsVar ->
       msg "abbrev. body cannot reduce to a variable"
end

(* -------------------------------------------------------------------- *)
module CloneError : sig
  open EcThCloning

  val string_of_ovkind : ovkind -> string
  val pp_clone_error : env -> Format.formatter -> clone_error -> unit
end = struct
  open EcThCloning

  let string_of_ovkind = function
    | OVK_Type      -> "type"
    | OVK_Operator  -> "operator"
    | OVK_Predicate -> "predicate"
    | OVK_Abbrev    -> "abbreviation"
    | OVK_Theory    -> "theory"
    | OVK_Lemma     -> "lemma/axiom"
    | OVK_ModExpr   -> "module"
    | OVK_ModType   -> "module type"

  let pp_incompatible env fmt = function
    | NotSameNumberOfTyParam (exp, got) ->
        Format.fprintf fmt "contains %i type parameter instead of %i" got exp

    | DifferentType (exp, got) ->
      let ppe = EcPrinting.PPEnv.ofenv env in
      Format.fprintf fmt "has type %a instead of %a"
        (EcPrinting.pp_type ppe) got  (EcPrinting.pp_type ppe) exp
    | OpBody  ->
      Format.fprintf fmt "incompatible body"
    | TyBody  ->
      Format.fprintf fmt "incompatible type declaration"

  let pp_clone_error env fmt error =
    let msg x = Format.fprintf fmt x in

    match error with
    | CE_UnkTheory name ->
        msg "cannot find theory to clone: `%s'"
          (string_of_qsymbol name)

    | CE_DupOverride (kd, x) ->
        msg "the %s `%s' is instantiate twice"
          (string_of_ovkind kd) (string_of_qsymbol x)

    | CE_UnkOverride (kd, x) ->
        msg "unknown %s `%s'"
          (string_of_ovkind kd) (string_of_qsymbol x)

    | CE_UnkAbbrev x ->
        msg "unknown abbreviation: `%s'" (string_of_qsymbol x)

    | CE_TypeArgMism (kd, x) ->
        msg "type argument mismatch for %s `%s'"
          (string_of_ovkind kd) (string_of_qsymbol x)

    | CE_OpIncompatible (x, err) ->
        msg "operator `%s' body %a"
          (string_of_qsymbol x) (pp_incompatible env) err

    | CE_PrIncompatible (x, err) ->
        msg "predicate `%s' body %a"
          (string_of_qsymbol x) (pp_incompatible env) err

    | CE_TyIncompatible (x, err) ->
        msg "type `%s` %a"
          (string_of_qsymbol x) (pp_incompatible env) err

    | CE_ModTyIncompatible x ->
        msg "module type `%s` is incompatible"
          (string_of_qsymbol x)

    | CE_ModIncompatible x ->
        msg "module `%s` is incompatible"
          (string_of_qsymbol x)

    | CE_InvalidRE x ->
        msg "invalid regexp: `%s'" x

    | CE_InlinedOpIsForm x ->
        msg
          "inlined operator's body must be an expression-like formula: `%s'"
          (string_of_qsymbol x)
end

(* -------------------------------------------------------------------- *)
module PTermError : sig
  open EcProofTerm

  val string_of_argkind : argkind -> string
  val pp_pterm_apperror : Format.formatter -> pterror -> unit
end = struct
  open EcProofTerm
  open TypingError

  let string_of_argkind (ak : argkind) =
    match ak with
    | `Form  -> "formula"
    | `Mem   -> "memory"
    | `Mod   -> "module"
    | `PTerm -> "proof-term"

  let pp_pterm_apperror fmt (((hyps, ue, ev), kind) : pterror) =
    let msg x = Format.fprintf fmt x in

    match kind with
    | AE_WrongArgKind (src, dst) ->
         msg "expecting a `%s', not a `%s'"
           (string_of_argkind dst) (string_of_argkind src)

    | AE_CannotInfer     -> msg "%s" "cannot infer this placeholder"
    | AE_CannotInferMod  -> msg "%s" "cannot infer module arguments"
    | AE_NotFunctional   -> msg "%s" "too many arguments"

    | AE_InvalidArgForm (IAF_Mismatch (src, dst)) ->
       let ppe = EcPrinting.PPEnv.ofenv (LDecl.toenv hyps) in
       let uidmap = EcUnify.UniEnv.assubst ue in
       let dst = ty_subst (Tuni.subst uidmap) dst in

       msg "This expression has type@\n";
       msg "  @[<hov 2>%a@]@\n@\n" (EcPrinting.pp_type ppe) src;
       msg "but is expected to have type@\n";
       msg "  @[<hov 2>%a@]" (EcPrinting.pp_type ppe) dst

    | AE_InvalidArgForm (IAF_TyError (env, err)) ->
       msg "This proof-term argument is not a valid formula:@\n@\n";
       msg "  @[<hov 2>%a@]@\n" (pp_tyerror env) err

    | AE_InvalidArgMod cnv_failure ->
      msg "@[<v 2>%s@;@[%a@]@]"
        "invalid argument (incompatible module type):"
        (TypingError.pp_cnv_failure (LDecl.toenv hyps)) cnv_failure

    | AE_InvalidArgProof (src, dst) ->
       let ppe = EcPrinting.PPEnv.ofenv (LDecl.toenv hyps) in
       let sb  = EcMatching.CPTEnv (EcMatching.MEV.assubst ue ev) in
       let src = concretize_e_form sb src in
       let dst = concretize_e_form sb dst in

       msg "this proof-term proves:@\n@\n";
       msg "  @[<hov 2>%a@]@\n@\n" (EcPrinting.pp_form ppe) src;
       msg "but is expected to prove:@\n@\n";
       msg "  @[<hov 2>%a@]@\n" (EcPrinting.pp_form ppe) dst

    | AE_InvalidArgModRestr e ->
       msg "%a" (pp_restr_error (LDecl.toenv hyps)) e
end

(* -------------------------------------------------------------------- *)
let pp_apply_error fmt (dpe, reason, pt, (src, dst)) =
  let module PT = EcProofTerm in

  let ppe = EcPrinting.PPEnv.ofenv (LDecl.toenv pt.PT.pte_hy) in
  let src = PT.concretize_form pt src in

  Format.fprintf fmt "the given proof-term proves:@\n@\n";
  Format.fprintf fmt "  @[%a@]@\n@\n" (EcPrinting.pp_form ppe) src;
  match reason with
  | `DoNotMatch ->
       Format.fprintf fmt "it does not apply to the goal@\n@\n";
       if dpe then begin
         Format.fprintf fmt "  @[%a@]@\n@\n" (EcPrinting.pp_form ppe) dst
       end;
  | `IncompleteInference ->
       Format.fprintf fmt "not all variables can be inferred@\n"

(* -------------------------------------------------------------------- *)
let pp_parse_error fmt msg =
  match msg with
  | Some msg -> Format.fprintf fmt "parse error: %s" msg
  | None     -> Format.fprintf fmt "parse error"

(* -------------------------------------------------------------------- *)
let pp_alias_clash env fmt = function
  | EcPV.AC_concrete_abstract (mp, npv) ->
      let top = m_functor npv.x_top in
      let ppe = EcPrinting.PPEnv.ofenv env in
      Format.fprintf fmt
        "The module %a can write %a (maybe add restriction %a)"
        (EcPrinting.pp_topmod ppe) mp
        (EcPrinting.pp_pv ppe) (pv_glob npv)
        (EcPrinting.pp_topmod ppe) top

  | EcPV.AC_abstract_abstract (mp, mp') ->
    let ppe = EcPrinting.PPEnv.ofenv env in
    Format.fprintf fmt
      "The module %a can write %a (add restriction %a to %a, or %a to %a)"
      (EcPrinting.pp_topmod ppe) mp
      (EcPrinting.pp_topmod ppe) mp'
      (EcPrinting.pp_topmod ppe) mp
      (EcPrinting.pp_topmod ppe) mp'
      (EcPrinting.pp_topmod ppe) mp'
      (EcPrinting.pp_topmod ppe) mp

(* -------------------------------------------------------------------- *)
module RedError : sig
  open EcFol

  val pp_incompatible_form : Format.formatter -> env -> form pair -> unit
  val pp_incompatible_type : Format.formatter -> env -> ty pair -> unit
end = struct
  module PE = EcPrinting

  let pp_incompatible_form fmt env (f1, f2) =
    Format.fprintf fmt
      "the formula %a is not compatible with %a\n%!"
      (PE.pp_form (PE.PPEnv.ofenv env)) f1
      (PE.pp_form (PE.PPEnv.ofenv env)) f2

  let pp_incompatible_type fmt env (t1, t2) =
    Format.fprintf fmt
      "the type %a is not compatible with %a\n%!"
      (PE.pp_type (PE.PPEnv.ofenv env)) t1
      (PE.pp_type (PE.PPEnv.ofenv env)) t2
end

(* -------------------------------------------------------------------- *)
let pp_tc_error fmt error =
  let module G = EcCoreGoal in

  let pname, penv =
    match error.G.tc_reloced with
    | Some (name, ppgoal) ->
        (Some name, if ppgoal then error.G.tc_proofenv else None)
    | None -> (None, None)
  in

  let pp_penv penv =
    let goal = G.FApi.get_main_pregoal penv in
    let ppe = EcPrinting.PPEnv.ofenv (LDecl.toenv goal.G.g_hyps) in

    Format.fprintf fmt "\nInitial goal was:\n\n%!";
    Format.fprintf fmt "%a\n%!"
      (EcPrinting.pp_goal ppe (oget !ppo).ppo_prpo)
      ((LDecl.tohyps goal.G.g_hyps, goal.G.g_concl), `One (-1))

  in

  pname |> oiter (Format.fprintf fmt "In proving `%s':\n\n%!");
  (match error.G.tc_message with
   | G.TCEUser (x, f) ->
      Format.fprintf fmt "%s\n%!" (f x)
   | G.TCEExn e ->
      Format.fprintf fmt "%a" EcPException.exn_printer e);
  penv |> oiter pp_penv

(* -------------------------------------------------------------------- *)
let pp_error_clear fmt err =
  let pp_id fmt id = Format.fprintf fmt "%s" (EcIdent.name id) in
  match Lazy.force err with
  | `ClearInGoal xs ->
      Format.fprintf fmt
        "cannot clear %a that is/are used in the conclusion"
        (EcPrinting.pp_list ",@ " pp_id) xs
  | `ClearDep (x, y) ->
      Format.fprintf fmt
        "cannot clear %a that is used in %a"
        pp_id x pp_id y

(* -------------------------------------------------------------------- *)
let pp fmt exn =
  match exn with
  | EcHiInductive.RcError (_, env, e) -> InductiveError.pp_rcerror env fmt e
  | EcHiInductive.DtError (_, env, e) -> InductiveError.pp_dterror env fmt e
  | EcHiInductive.FxError (_, env, e) -> InductiveError.pp_fxerror env fmt e

  | EcHiPredicates.TransPredError (_, env, e) ->
     PredError.pp_tperror env fmt e

  | EcHiNotations.NotationError (_, env, e) ->
     NotationsError.pp_nterror env fmt e

  | EcPV.AliasClash (env, ac) ->
      pp_alias_clash env fmt ac

  | EcThCloning.CloneError (env, e) ->
      CloneError.pp_clone_error env fmt e

  | EcCoreGoal.TcError error ->
      pp_tc_error fmt error

  | EcParsetree.ParseError (_loc, msg) ->
      pp_parse_error fmt msg

  | EcReduction.IncompatibleForm (env, (f1, f2)) ->
      RedError.pp_incompatible_form fmt env (f1, f2)

  | EcReduction.IncompatibleType (env, (t1, t2)) ->
      RedError.pp_incompatible_type fmt env (t1, t2)

  | EcTyping.TyError (_, env, e) ->
      TypingError.pp_tyerror env fmt e

  | EcTyping.RestrictionError (env, e) ->
      TypingError.pp_restr_error env fmt e

  | EcProofTerm.ProofTermError e ->
      PTermError.pp_pterm_apperror fmt e

  | EcCoreGoal.ClearError e ->
      pp_error_clear fmt e

  | EcLowGoal.Apply.NoInstance e ->
      pp_apply_error fmt e

  | _ -> raise exn

(* -------------------------------------------------------------------- *)
let register =
  let first = ref true in fun () ->
  if !first then EcPException.register pp; first := false
