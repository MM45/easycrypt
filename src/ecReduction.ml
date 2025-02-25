(* -------------------------------------------------------------------- *)
open EcUtils
open EcIdent
open EcPath
open EcTypes
open EcDecl
open EcModules
open EcFol
open EcEnv

module BI = EcBigInt

(* -------------------------------------------------------------------- *)
exception IncompatibleType of env * (ty * ty)
exception IncompatibleForm of env * (form * form)
exception IncompatibleExpr of env * (expr * expr)

(* -------------------------------------------------------------------- *)
type 'a eqtest  = env -> 'a -> 'a -> bool
type 'a eqntest = env -> ?norm:bool -> 'a -> 'a -> bool
type 'a eqantest = env -> ?alpha:(EcIdent.t * ty) Mid.t -> ?norm:bool -> 'a -> 'a -> bool

module EqTest_base = struct
  let rec for_type env t1 t2 =
    ty_equal t1 t2 || for_type_r env t1 t2

  and for_type_r env t1 t2 =
    match t1.ty_node, t2.ty_node with
    | Tunivar uid1, Tunivar uid2 -> EcUid.uid_equal uid1 uid2

    | Tvar i1, Tvar i2 -> i1 = i2

    | Ttuple lt1, Ttuple lt2 ->
          List.length lt1 = List.length lt2
       && List.all2 (for_type env) lt1 lt2

    | Tfun (t1, t2), Tfun (t1', t2') ->
        for_type env t1 t1' && for_type env t2 t2'

    | Tglob mp, _ when EcEnv.NormMp.tglob_reducible env mp ->
        for_type env (EcEnv.NormMp.norm_tglob env mp) t2

    | _, Tglob mp when EcEnv.NormMp.tglob_reducible env mp ->
        for_type env t1 (EcEnv.NormMp.norm_tglob env mp)

    | Tconstr (p1, lt1), Tconstr (p2, lt2) when EcPath.p_equal p1 p2 ->
        if
             List.length lt1 = List.length lt2
          && List.all2 (for_type env) lt1 lt2
        then true
        else
          if   Ty.defined p1 env
          then for_type env (Ty.unfold p1 lt1 env) (Ty.unfold p2 lt2 env)
          else false

    | Tconstr(p1,lt1), _ when Ty.defined p1 env ->
        for_type env (Ty.unfold p1 lt1 env) t2

    | _, Tconstr(p2,lt2) when Ty.defined p2 env ->
        for_type env t1 (Ty.unfold p2 lt2 env)

    | _, _ -> false

  (* ------------------------------------------------------------------ *)
  let is_unit env ty = for_type env tunit ty
  let is_bool env ty = for_type env tbool ty
  let is_int  env ty = for_type env tint  ty

  (* ------------------------------------------------------------------ *)
  let for_type_exn env t1 t2 =
    if not (for_type env t1 t2) then
      raise (IncompatibleType (env, (t1, t2)))

  (* ------------------------------------------------------------------ *)
  let for_pv env ~norm p1 p2 =
    pv_equal p1 p2 || (norm && (pv_kind p1 = pv_kind p2) &&
      let p1 = NormMp.norm_pvar env p1 in
      let p2 = NormMp.norm_pvar env p2 in
      pv_equal p1 p2)

  (* ------------------------------------------------------------------ *)
  let for_xp env ~norm p1 p2 =
     EcPath.x_equal p1 p2 || (norm &&
       let p1 = NormMp.norm_xfun env p1 in
       let p2 = NormMp.norm_xfun env p2 in
       EcPath.x_equal p1 p2)

  (* ------------------------------------------------------------------ *)
  let for_mp env ~norm p1 p2 =
     EcPath.m_equal p1 p2 || (norm &&
       let p1 = NormMp.norm_mpath env p1 in
       let p2 = NormMp.norm_mpath env p2 in
       EcPath.m_equal p1 p2)

  (* ------------------------------------------------------------------ *)
  let for_expr env ~norm =
    let module E = struct exception NotConv end in

    let find alpha id = odfl id (omap fst (Mid.find_opt id alpha)) in

    let noconv (f : expr -> expr -> bool) e1 e2 =
      try f e1 e2 with E.NotConv -> false in

    let check_binding env alpha (id1, ty1) (id2, ty2) =
      if not (for_type env ty1 ty2) then
        raise E.NotConv;
      Mid.add id1 (id2, ty2) alpha in

    let check_bindings env alpha b1 b2 =
      if List.length b1 <> List.length b2 then
        raise E.NotConv;
      List.fold_left2 (check_binding env) alpha b1 b2 in

    let check_lpattern alpha lp1 lp2 =
      match lp1, lp2 with
      | LSymbol (id1, _), LSymbol (id2, ty2) ->
          Mid.add id1 (id2, ty2) alpha

      | LTuple lid1, LTuple lid2 when List.length lid1 = List.length lid2 ->
          List.fold_left2
            (fun alpha (id1, _) (id2, ty2) -> Mid.add id1 (id2, ty2) alpha)
            alpha lid1 lid2

      | _, _ -> raise E.NotConv in

    let rec aux alpha e1 e2 =
      e_equal e1 e2 || aux_r alpha e1 e2

    and aux_r alpha e1 e2 =
      match e1.e_node, e2.e_node with
      | Eint i1, Eint i2 ->
          BI.equal i1 i2

      | Elocal id1, Elocal id2 ->
          EcIdent.id_equal (find alpha id1) id2

      | Evar p1, Evar p2 ->
          for_pv env ~norm p1 p2

      | Eop(o1,ty1), Eop(o2,ty2) ->
          p_equal o1 o2 && List.all2 (for_type env) ty1 ty2

      | Equant(q1,b1,e1), Equant(q2,b2,e2) when qt_equal q1 q2 ->
          let alpha = check_bindings env alpha b1 b2 in
          noconv (aux alpha) e1 e2

      | Eapp (f1, args1), Eapp (f2, args2) ->
          aux alpha f1 f2 && List.all2 (aux alpha) args1 args2

      | Elet (p1, f1', g1), Elet (p2, f2', g2) ->
          aux alpha f1' f2'
            && noconv (aux (check_lpattern alpha p1 p2)) g1 g2

      | Etuple args1, Etuple args2 -> List.all2 (aux alpha) args1 args2

      | Eif (a1,b1,c1), Eif(a2,b2,c2) ->
          aux alpha a1 a2 && aux alpha b1 b2 && aux alpha c1 c2

      | Ematch (e1,es1,ty1), Ematch(e2,es2,ty2) ->
          for_type env ty1 ty2
            && List.all2 (aux alpha) (e1::es1) (e2::es2)

      | _, _ -> false

    in fun alpha e1 e2 -> aux alpha e1 e2

  (* ------------------------------------------------------------------ *)
  let for_lv env ~norm lv1 lv2 =
    match lv1, lv2 with
    | LvVar(p1, _), LvVar(p2, _) ->
        for_pv env ~norm p1 p2

    | LvTuple p1, LvTuple p2 ->
        List.all2
          (fun (p1, _) (p2, _) -> for_pv env ~norm p1 p2)
          p1 p2

    | _, _ -> false
end

(* -------------------------------------------------------------------- *)
module EqMod_base(Fe : sig
  val for_expr : env -> norm:bool -> (ident * ty) Mid.t -> expr -> expr -> bool
end) = struct
  open EqTest_base
  open Fe

  (* ------------------------------------------------------------------ *)
  let rec for_stmt env alpha ~norm s1 s2 =
       s_equal s1 s2
    || List.all2 (for_instr env alpha ~norm) s1.s_node s2.s_node

  (* ------------------------------------------------------------------ *)
  and for_instr env alpha ~norm i1 i2 =
    i_equal i1 i2 || for_instr_r env alpha ~norm i1 i2

  (* ------------------------------------------------------------------ *)
  and for_instr_r env alpha ~norm i1 i2 =
    match i1.i_node, i2.i_node with
    | Sasgn (lv1, e1), Sasgn (lv2, e2) ->
           for_lv env ~norm lv1 lv2
        && for_expr env alpha ~norm e1 e2

    | Srnd (lv1, e1), Srnd (lv2, e2) ->
           for_lv env ~norm lv1 lv2
        && for_expr env alpha ~norm e1 e2

    | Scall (lv1, f1, e1), Scall (lv2, f2, e2) ->
        oall2 (for_lv env ~norm) lv1 lv2
          && for_xp env ~norm f1 f2
          && List.all2 (for_expr env alpha ~norm) e1 e2

    | Sif (a1, b1, c1), Sif(a2, b2, c2) ->
        for_expr env alpha ~norm a1 a2
          && for_stmt env alpha ~norm b1 b2
          && for_stmt env alpha ~norm c1 c2

    | Swhile(a1,b1), Swhile(a2,b2) ->
           for_expr env alpha ~norm a1 a2
        && for_stmt env alpha ~norm b1 b2

    | Smatch(e1,bs1), Smatch(e2,bs2)
        when List.length bs1 = List.length bs2
      -> begin
        let module E = struct exception NotConv end in

        let check_branch (xs1, s1) (xs2, s2) =
          if List.length xs1 <> List.length xs2 then
            raise E.NotConv;
          let alpha =
            let do1 alpha (id1, ty1) (id2, ty2) =
              if not (for_type env ty1 ty2) then
                raise E.NotConv;
              Mid.add id1 (id2, ty2) alpha in
            List.fold_left2 do1 alpha xs1 xs2
          in for_stmt env alpha ~norm s1 s2 in

        try
             for_expr env alpha ~norm e1 e2
          && List.all2 (check_branch) bs1 bs2
        with E.NotConv -> false
      end

    | Sassert a1, Sassert a2 ->
        for_expr env alpha ~norm a1 a2

    | Sabstract id1, Sabstract id2 ->
        EcIdent.id_equal id1 id2

    | _, _ -> false

  (* -------------------------------------------------------------------- *)
  let for_funsig env fs1 fs2 =
    fs1.fs_name = fs2.fs_name &&
    for_type env fs1.fs_arg fs2.fs_arg &&
    for_type env fs1.fs_ret fs2.fs_ret

  (* -------------------------------------------------------------------- *)
  let add_modules p1 p2 : EcSubst.subst =
    List.fold_left2 (fun s (id1,_) (id2,_) ->
        EcSubst.add_module s id1 (EcPath.mident id2)) EcSubst.empty p1 p2

  (* ------------------------------------------------------------------ *)
  let rec for_module_type env ~norm mt1 mt2 =
    if EcPath.p_equal mt1.mt_name mt2.mt_name then
      let p1 = mt1.mt_params in
      let p2 = mt2.mt_params in
      List.for_all2
        (fun (_,mt1) (_,mt2) -> for_module_type env ~norm mt1 mt2) p1 p2 &&
        let s = add_modules p2 p1 in
        let args1 = mt1.mt_args in
        let args2 = List.map (EcSubst.subst_mpath s) mt2.mt_args in
        List.for_all2 (for_mp env ~norm) args1 args2
    else if norm then
      let s1 = EcEnv.ModTy.sig_of_mt env mt1 in
      let s2 = EcEnv.ModTy.sig_of_mt env mt2 in
      for_module_sig env ~norm s1 s2
    else
      false

  (* ------------------------------------------------------------------ *)
  and for_module_sig_body_item env i1 i2 =
    match i1, i2 with
    | Tys_function fs1, Tys_function fs2 ->
        for_funsig env fs1 fs2

  (* ------------------------------------------------------------------ *)
  and for_module_sig_body env b1 b2 =
    List.for_all2 (for_module_sig_body_item env) b1 b2

  (* ------------------------------------------------------------------ *)
  and for_module_sig env ~norm ms1 ms2 =
    let p1 = ms1.mis_params in
    let p2 = ms2.mis_params in
    List.for_all2
      (fun (_,mt1) (_,mt2) -> for_module_type env ~norm mt1 mt2) p1 p2 &&
    let s = add_modules p2 p1 in
    let body1 = ms1.mis_body in
    let body2 = EcSubst.subst_modsig_body s ms2.mis_body in
    for_module_sig_body env body1 body2

  (* ------------------------------------------------------------------ *)
  let for_variable env v1 v2 =
    v1.v_name = v2.v_name && for_type env v1.v_type v2.v_type

  (* ------------------------------------------------------------------ *)
  let for_function_def env ~norm fd1 fd2 =
    let cmp_v v1 v2 = compare v1.v_name v2.v_name in
    let locals1 = List.sort cmp_v fd1.f_locals in
    let locals2 = List.sort cmp_v fd2.f_locals in
    List.for_all2 (for_variable env) locals1 locals2 &&
    for_stmt env Mid.empty ~norm fd1.f_body fd2.f_body &&
      oall2 (for_expr env Mid.empty ~norm) fd1.f_ret fd2.f_ret

  (* ------------------------------------------------------------------ *)
  (* FIXME: FBalias FBdef *)
  let for_function_body env ~norm (fb1 : function_body) fb2 =
    match fb1, fb2 with
    | FBdef fd1, FBdef fd2 ->
      for_function_def env ~norm fd1 fd2

    | FBalias xp1, FBalias xp2 ->
      for_xp env ~norm xp1 xp2

    | FBabs restr1, FBabs restr2 ->
       (* Should we use PreOI.equal (for_form env ~norm) *)
       OI.equal restr1 restr2

    | FBabs _, _ | _, FBabs _ -> assert false
    | _, _ -> false

  let for_function env ~norm f1 f2 =
    f1.f_name = f2.f_name &&
      for_funsig env f1.f_sig f2.f_sig &&
        for_function_body env ~norm f1.f_def f2.f_def

  (* ------------------------------------------------------------------ *)
  let rec for_module_expr env ~norm ~body me1 me2 =
    me1.me_name = me2.me_name &&
      for_module_sig_body env me1.me_sig_body me2.me_sig_body &&
    let s = add_modules me2.me_params me1.me_params in
    let comps1 = me1.me_comps in
    let comps2 = EcSubst.subst_module_comps s me2.me_comps in

    if not (for_module_comps env ~norm ~body comps1 comps2) then
      false
    else if body then
      let body1 = me1.me_body in
      let body2 = EcSubst.subst_module_body s me2.me_body in
      for_module_body env ~norm ~body body1 body2
    else true

  (* ------------------------------------------------------------------ *)
  and for_module_comps env ~norm ~body mc1 mc2 =
    List.for_all2 (for_module_item env ~norm ~body) mc1 mc2

  (* ------------------------------------------------------------------ *)
  and for_module_item env ~norm ~body i1 i2 =
    match i1, i2 with
    | MI_Module me1, MI_Module me2 ->
      for_module_expr env ~norm ~body me1 me2

    | MI_Variable v1, MI_Variable v2 ->
      for_variable env v1 v2

    | MI_Function f1, MI_Function f2 ->
      for_function env ~norm f1 f2

    | _, _ -> false

  (* ------------------------------------------------------------------ *)
  and for_module_body env ~norm ~body mb1 mb2 =
    match mb1, mb2 with
    | ME_Alias(i1, mp1), ME_Alias(i2, mp2) ->
      i1 = i2 && for_mp env ~norm mp1 mp2

    | ME_Structure {ms_body = mc1}, ME_Structure {ms_body = mc2} ->
      for_module_comps env ~norm ~body mc1 mc2

    | ME_Decl _, _ | _, ME_Decl _ -> assert false
    | _, _ -> false
end


(* -------------------------------------------------------------------- *)
module EqTest_i = struct
  include EqTest_base
  include EqMod_base(EqTest_base)

  (* ------------------------------------------------------------------ *)
  let for_pv    = fun env ?(norm = true) -> for_pv    env ~norm
  let for_xp    = fun env ?(norm = true) -> for_xp    env ~norm
  let for_mp    = fun env ?(norm = true) -> for_mp    env ~norm
  let for_instr = fun env ?(norm = true) -> for_instr env Mid.empty ~norm
  let for_stmt  = fun env ?(norm = true) -> for_stmt  env Mid.empty ~norm
  let for_expr  = fun env ?(norm = true) -> for_expr  env Mid.empty ~norm
end

(* -------------------------------------------------------------------- *)
exception NotConv

let ensure b = if b then () else raise NotConv

let check_ty env subst ty1 ty2 =
  ensure (EqTest_base.for_type env ty1 (EcSubst.subst_ty subst ty2))

let add_local (env, subst) (x1, ty1) (x2, ty2) =
  check_ty env subst ty1 ty2;
  env,
  if id_equal x1 x2 then subst
  else EcSubst.rename_flocal subst x2 x1 ty1

let check_lpattern env subst lp1 lp2 =
    match lp1, lp2 with
    | LSymbol xt1, LSymbol xt2 -> add_local (env, subst) xt1 xt2
    | LTuple lid1, LTuple lid2 when List.length lid1 = List.length lid2 ->
      List.fold_left2 add_local (env,subst) lid1 lid2
    | _, _ -> raise NotConv

let check_memtype env mt1 mt2 =
  ensure (EcMemory.mt_equal_gen (EqTest_i.for_type env) mt1 mt2)

let check_binding test (env, subst) (x1, gty1) (x2, gty2) =
  let gty2 = EcSubst.subst_gty subst gty2 in
  match gty1, gty2 with
  | GTty ty1, GTty ty2 ->
    add_local (env, subst) (x1,ty1) (x2,ty2)

  | GTmodty p1, GTmodty p2 ->
    let test f1 f2 = test env subst f1 f2 in
    ensure (ModTy.mod_type_equiv test env p1 p2);
    Mod.bind_local x1 p1 env,
    if id_equal x1 x2 then subst
    else EcSubst.add_module subst x2 (EcPath.mident x1)

  | GTmem me1, GTmem me2  ->
    check_memtype env me1 me2;
    env,
    if id_equal x1 x2 then subst
    else EcSubst.add_memory subst x2 x1
  | _, _ -> raise NotConv

let check_bindings test env subst bd1 bd2 =
    List.fold_left2 (check_binding test) (env,subst) bd1 bd2

let check_cost_l env subst co1 co2 =
    let calls1 =
      EcPath.Mx.fold (fun f c calls ->
          let f' = NormMp.norm_xfun env f in
          EcPath.Mx.change (fun old -> assert (old = None); Some c) f' calls
        ) co1.c_calls EcPath.Mx.empty
    and calls2 =
      EcPath.Mx.fold (fun f c calls ->
          let f' = EcSubst.subst_xpath subst f in
          let f' = NormMp.norm_xfun env f' in
          EcPath.Mx.change (fun old -> assert (old = None); Some c) f' calls
        ) co2.c_calls EcPath.Mx.empty in

    let aco, aca =
      EcPath.Mx.fold2_union (fun _ a1 a2 (aco, aca) ->
          match a1,a2 with
          | None, None -> assert false
          | None, Some _ | Some _, None -> raise NotConv
          | Some cb1, Some cb2 ->
              ((cb1.cb_cost  , cb2.cb_cost  ) :: aco,
               (cb1.cb_called, cb2.cb_called) :: aca)
        ) calls1 calls2 ([], []) in

    (co1.c_self, co2.c_self) :: aco @ aca

let check_cost test env subst co1 co2 =
  List.iter
    (fun (a1,a2) -> test env subst a1 a2)
    (check_cost_l env subst co1 co2)

let check_e env s e1 e2 =
  let e2 = EcSubst.subst_expr s e2 in
  if not (EqTest_i.for_expr env e1 e2) then raise NotConv

let is_alpha_eq_e env e1 e2 =
  try check_e env EcSubst.empty e1 e2; true with NotConv -> false

(* -------------------------------------------------------------------- *)
let is_alpha_eq hyps f1 f2 =
  let env = LDecl.toenv hyps in
  let error () = raise NotConv in
  let ensure t = if not t then error () in

  let check_local subst id1 f2 =
    match (EcSubst.subst_flocal subst f2).f_node with
    | Flocal id2 -> ensure (EcIdent.id_equal id1 id2)
    | _ -> assert false in

  let check_mem subst m1 m2 =
    let m2 = EcSubst.subst_mem subst m2 in
    ensure (EcIdent.id_equal m1 m2) in

  let check_pv env subst pv1 pv2 =
    let pv2 = EcSubst.subst_progvar subst pv2 in
    ensure (EqTest_i.for_pv env pv1 pv2) in

  let check_mp env subst mp1 mp2 =
    let mp2 = EcSubst.subst_mpath subst mp2 in
    ensure (EqTest_i.for_mp env mp1 mp2) in

  let check_xp env subst xp1 xp2 =
    let xp2 = EcSubst.subst_xpath subst xp2 in
    ensure (EqTest_i.for_xp env xp1 xp2) in

  let check_s env s s1 s2 =
    let s2 = EcSubst.subst_stmt s s2 in
    ensure (EqTest_i.for_stmt env s1 s2) in

  let rec aux env subst f1 f2 =
    if subst = EcSubst.empty && f_equal f1 f2 then ()
    else match f1.f_node, f2.f_node with

    | Fquant(q1,bd1,f1'), Fquant(q2,bd2,f2') when
        q1 = q2 && List.length bd1 = List.length bd2 ->

      let env, subst = check_bindings test env subst bd1 bd2 in
      aux env subst f1' f2'

    | Fif(a1,b1,c1), Fif(a2,b2,c2) ->
      aux env subst a1 a2; aux env subst b1 b2; aux env subst c1 c2

    | Fmatch(f1,bs1,ty1), Fmatch(f2,bs2,ty2) ->
      if List.length bs1 <> List.length bs2 then
        error ();
      aux env subst f1 f2;
      ensure (EqTest_i.for_type env ty1 ty2);
      List.iter2 (aux env subst) bs1 bs2

    | Flet(p1,f1',g1), Flet(p2,f2',g2) ->
      aux env subst f1' f2';
      let (env,subst) = check_lpattern env subst p1 p2 in
      aux env subst g1 g2

    | Fint i1, Fint i2 when EcBigInt.equal i1 i2 -> ()

    | Flocal id1, Flocal _ -> check_local subst id1 f2

    | Fpvar(p1,m1), Fpvar(p2,m2) ->
      check_mem subst m1 m2;
      check_pv env subst p1 p2

    | Fglob(p1,m1), Fglob(p2,m2) ->
      check_mem subst m1 m2;
      check_mp env subst p1 p2

    | Fop(p1, ty1), Fop(p2, ty2) when EcPath.p_equal p1 p2 ->
      List.iter2 (check_ty env subst) ty1 ty2

    | Fapp(f1',args1), Fapp(f2',args2) when
        List.length args1 = List.length args2 ->
      aux env subst f1' f2';
      List.iter2 (aux env subst) args1 args2

    | Ftuple args1, Ftuple args2 when List.length args1 = List.length args2 ->
      List.iter2 (aux env subst) args1 args2

    | Fproj(f1,i1), Fproj(f2,i2) when i1 = i2 ->
      aux env subst f1 f2

    | FhoareF hf1, FhoareF hf2 ->
      check_xp env subst hf1.hf_f hf2.hf_f;
      aux env subst hf1.hf_pr hf2.hf_pr;
      aux env subst hf1.hf_po hf2.hf_po

    | FhoareS hs1, FhoareS hs2 ->
      check_s env subst hs1.hs_s hs2.hs_s;
      (* FIXME should check the memenv *)
      aux env subst hs1.hs_pr hs2.hs_pr;
      aux env subst hs1.hs_po hs2.hs_po

    | FbdHoareF hf1, FbdHoareF hf2 ->
      ensure (hf1.bhf_cmp = hf2.bhf_cmp);
      check_xp env subst hf1.bhf_f hf2.bhf_f;
      aux env subst hf1.bhf_pr hf2.bhf_pr;
      aux env subst hf1.bhf_po hf2.bhf_po;
      aux env subst hf1.bhf_bd hf2.bhf_bd

    | FbdHoareS hs1, FbdHoareS hs2 ->
      ensure (hs1.bhs_cmp = hs2.bhs_cmp);
      check_s env subst hs1.bhs_s hs2.bhs_s;
      (* FIXME should check the memenv *)
      aux env subst hs1.bhs_pr hs2.bhs_pr;
      aux env subst hs1.bhs_po hs2.bhs_po;
      aux env subst hs1.bhs_bd hs2.bhs_bd

    | FcHoareF chf1, FcHoareF chf2 ->
      check_xp env subst chf1.chf_f chf2.chf_f;
      aux env subst chf1.chf_pr chf2.chf_pr;
      aux env subst chf1.chf_po chf2.chf_po;
      check_cost aux env subst chf1.chf_co chf2.chf_co

    | FcHoareS chs1, FcHoareS chs2 ->
      check_s env subst chs1.chs_s chs2.chs_s;
      (* FIXME should check the memenv *)
      aux env subst chs1.chs_pr chs2.chs_pr;
      aux env subst chs1.chs_po chs2.chs_po;
      check_cost aux env subst chs1.chs_co chs2.chs_co

    | FequivF ef1, FequivF ef2 ->
      check_xp env subst ef1.ef_fl ef2.ef_fl;
      check_xp env subst ef1.ef_fr ef2.ef_fr;
      aux env subst ef1.ef_pr ef2.ef_pr;
      aux env subst ef1.ef_po ef2.ef_po

    | FequivS es1, FequivS es2 ->
      check_s env subst es1.es_sl es2.es_sl;
      check_s env subst es1.es_sr es2.es_sr;
      (* FIXME should check the memenv *)
      aux env subst es1.es_pr es2.es_pr;
      aux env subst es1.es_po es2.es_po

    | FeagerF eg1, FeagerF eg2 ->
      check_xp env subst eg1.eg_fl eg2.eg_fl;
      check_xp env subst eg1.eg_fr eg2.eg_fr;
      aux env subst eg1.eg_pr eg2.eg_pr;
      aux env subst eg1.eg_po eg2.eg_po;
      check_s env subst eg1.eg_sl eg2.eg_sl;
      check_s env subst eg1.eg_sr eg2.eg_sr

    | Fpr pr1, Fpr pr2 ->
      check_mem subst pr1.pr_mem pr2.pr_mem;
      check_xp env subst pr1.pr_fun pr2.pr_fun;
      aux env subst pr1.pr_args pr2.pr_args;
      aux env subst pr1.pr_event pr2.pr_event

    | Fcoe coe1, Fcoe coe2 ->
      check_e env subst coe1.coe_e coe2.coe_e;
      let bd1 = fst coe1.coe_mem, GTmem (snd coe1.coe_mem) in
      let bd2 = fst coe2.coe_mem, GTmem (snd coe2.coe_mem) in
      let env, subst = check_bindings test env subst [bd1] [bd2] in
      aux env subst coe1.coe_pre coe2.coe_pre;

    | _, _ -> error ()

  and test env subst f1 f2 =
    try aux env subst f1 f2; true with
    | NotConv -> false
  in

  try aux env EcSubst.empty f1 f2; true
  with NotConv -> false

(* -------------------------------------------------------------------- *)
type reduction_info = {
  beta    : bool;
  delta_p : (path  -> deltap); (* reduce operators *)
  delta_h : (ident -> bool);   (* reduce local definitions *)
  zeta    : bool;
  iota    : bool;
  eta     : bool;
  logic   : rlogic_info;
  modpath : bool;
  user    : bool;
  cost    : bool;
}

and deltap      = [Op.redmode | `No]
and rlogic_info = [`Full | `ProductCompat] option

(* -------------------------------------------------------------------- *)
let full_red = {
  beta    = true;
  delta_p = (fun _ -> `IfTransparent);
  delta_h = EcUtils.predT;
  zeta    = true;
  iota    = true;
  eta     = true;
  logic   = Some `Full;
  modpath = true;
  user    = true;
  cost    = true;
}

let no_red = {
  beta    = false;
  delta_p = (fun _ -> `No);
  delta_h = EcUtils.pred0;
  zeta    = false;
  iota    = false;
  eta     = false;
  logic   = None;
  modpath = false;
  user    = false;
  cost    = false;
}

let beta_red     = { no_red with beta = true; }
let betaiota_red = { no_red with beta = true; iota = true; }

let nodelta =
  { full_red with
      delta_h = EcUtils.pred0;
      delta_p = (fun _ -> `No); }

let delta = { no_red with delta_p = (fun _ -> `IfTransparent); }

let full_compat = { full_red with logic = Some `ProductCompat; }

(* -------------------------------------------------------------------- *)
type not_reducible = NoHead | NeedSubTerm

exception NotRed of not_reducible

let nohead = NotRed NoHead
let needsubterm = NotRed NeedSubTerm

(* -------------------------------------------------------------------- *)
let reduce_local ri hyps x  =
  if   ri.delta_h x
  then try LDecl.unfold x hyps with NotReducible -> raise nohead
  else raise nohead

let reduce_op ri env nargs p tys =
  match ri.delta_p p with
  | `No ->
     raise nohead

  | #Op.redmode as mode ->
     try
       Op.reduce ~mode ~nargs env p tys
     with NotReducible -> raise nohead

let is_record env f =
  match EcFol.destr_app f with
  | { f_node = Fop (p, _) }, _ -> EcEnv.Op.is_record_ctor env p
  | _ -> false

(* -------------------------------------------------------------------- *)
let can_eta x (f, args) =
  match List.rev args with
  | { f_node = Flocal y } :: args ->
      let check v = not (Mid.mem x v.f_fv) in
      id_equal x y && List.for_all check (f :: args)
  | _ -> false

let eta_expand bd f ty =
  let args =
    List.map (fun (x,gty) ->
        match gty with
        | GTty ty -> f_local x ty
        | _      -> assert false) bd in
  (f_app f args ty)

(* -------------------------------------------------------------------- *)
type mode =
  | UR_Form
  | UR_CostPre of EcMemory.memory
  | UR_CostExpr of EcMemory.memory

let is_UR_CostExpr = function UR_CostExpr _ -> true | _ -> false
let get_UR_CostExpr = function UR_CostExpr m -> m | _ -> assert false

(* -------------------------------------------------------------------- *)
let reduce_user_gen simplify ri env hyps f =
  if not ri.user then raise nohead;

  let p =
    match f.f_node with
    | Fop (p, _)
    | Fapp ({ f_node = Fop (p, _) }, _) -> `Path p
    | Ftuple _   -> `Tuple
    | Fcoe coe ->
      let inner =
        match coe.coe_e.e_node with
        | Eop (p, _)
        | Eapp ({ e_node = Eop (p, _) }, _) -> `Path p
        | Etuple _ -> `Tuple
        | _ -> raise nohead in
      `Cost inner
    | _ -> raise nohead in

  let rules = EcEnv.Reduction.get p env in

  if rules = [] then raise nohead;

  let module R = EcTheory in

  oget ~exn:needsubterm (List.Exceptionless.find_map (fun rule ->

    try
      let ue    = EcUnify.UniEnv.create None in
      let tvi   = EcUnify.UniEnv.opentvi ue rule.R.rl_tyd None in

      let check_alpha_eq f f' =
        if not (is_alpha_eq hyps f f') then raise NotReducible
      in

      (* for formula varibales *)
      let pv    = ref (Mid.empty : form Mid.t) in
      let check_pv x f =
        match Mid.find_opt x !pv with
        | None    -> pv := Mid.add x f !pv
        | Some f' -> check_alpha_eq f f' in

      (* for expression variables in schemata *)
      let e_pv  = ref (Mid.empty : expr Mid.t) in
      let check_e_pv mhr x f =
        match Mid.find_opt x !e_pv with
        | None    -> e_pv := Mid.add x (expr_of_form mhr f) !e_pv
        (* must use mhr, c.f. caller of check_e_pv *)

        | Some f' ->
          try check_e env EcSubst.empty (expr_of_form mhr f) f' with
          | NotConv -> raise NotReducible
        (* idem *)
      in

      (* for memory pred. variables in schemata *)
      let p_pv  = ref (Mid.empty : mem_pr Mid.t) in
      let check_p_pv m x f =
        match Mid.find_opt x !p_pv with
        | None    -> p_pv := Mid.add x (m,f) !p_pv
        | Some (m',f') ->
          (* We freshen the memory. *)
          (* FIXME: use inner function of check_alpha_equal *)
          let mf = EcIdent.fresh m in
          let fs  = Fsubst.f_bind_mem Fsubst.f_subst_id m  mf in
          let fs' = Fsubst.f_bind_mem Fsubst.f_subst_id m' mf in
          let f  = Fsubst.f_subst fs  f
          and f' = Fsubst.f_subst fs' f' in
          check_alpha_eq f f' in

      (* infered memtype, for schema application *)
      let sc_mt = ref None in

      let rec doit (mode : mode) f ptn =
        match destr_app f, ptn with
        | ({ f_node = Fop (p, tys) }, args), R.Rule (`Op (p', tys'), args')
              when EcPath.p_equal p p' && List.length args = List.length args' ->

          let tys' = List.map (EcTypes.Tvar.subst tvi) tys' in

          begin
            try  List.iter2 (EcUnify.unify env ue) tys tys'
            with EcUnify.UnificationFailure _ -> raise NotReducible end;

          List.iter2 (doit mode) args args'

        | ({ f_node = Ftuple args} , []), R.Rule (`Tuple, args')
            when List.length args = List.length args' ->
          List.iter2 (doit mode) args args'

        | ({ f_node = Fint i }, []), R.Int j when EcBigInt.equal i j ->
            ()

        | ({ f_node = Fcoe coe} , []), R.Cost (menv, inner_pre, inner_r)  ->
          if not ri.cost then
            raise NotReducible;

          (* Check memtype compatibility. *)
          if EcMemory.is_schema (snd menv) then begin
            if !sc_mt = None then
              sc_mt := Some (snd coe.coe_mem)
            else if not (EcMemory.mt_equal (snd coe.coe_mem) (oget !sc_mt))
            then raise NotReducible
            else () end
          else
            begin match
                EcMemory.mt_equal_gen (fun ty1 ty2 ->
                    let ty2 = EcTypes.Tvar.subst tvi ty2 in
                    EcUnify.unify env ue ty1 ty2; true
                  ) (snd coe.coe_mem) (snd menv)
              with
              | true -> ()
              | false -> assert false
              | exception (EcUnify.UnificationFailure _) -> raise NotReducible
            end;

          doit (UR_CostPre (fst coe.coe_mem)) coe.coe_pre inner_pre;

          (* use mhr, to be consistent with check_e_pv *)
          let mhr = fst coe.coe_mem in
          let e = form_of_expr mhr coe.coe_e in

          doit (UR_CostExpr mhr) e inner_r;

        | _, R.Var x when mode = UR_Form ->
          check_pv x f

        | _, R.Var x when is_UR_CostExpr mode ->
          let mhr = get_UR_CostExpr mode in
          check_e_pv mhr x f

        | _, R.Var x ->
          let m = match mode with
            | UR_CostPre m -> m
            | _ -> assert false in

            (* This case is more annoying. *)
          if List.mem_assoc x rule.rl_vars
          then check_pv x f
          else if List.mem_assoc x rule.rl_evars
          then check_e_pv m x f
          else begin
            assert (List.mem x rule.rl_pvars);
            check_p_pv m x f end

        | _ -> raise NotReducible in

      doit UR_Form f rule.R.rl_ptn;

      if not (EcUnify.UniEnv.closed ue) then
        raise NotReducible;

      let subst f =
        let uidmap = EcUnify.UniEnv.assubst ue in
        let ts = Tuni.subst uidmap in

        if (Mid.is_empty !e_pv) && (Mid.is_empty !p_pv)
        then   (* axiom case *)
          let subst   = Fsubst.f_subst_init ~sty:ts () in
          let subst   =
            Mid.fold (fun x f s -> Fsubst.f_bind_local s x f) !pv subst in
          Fsubst.f_subst subst (Fsubst.subst_tvar tvi f)

        else   (* schema case, which is more complicated *)
          let typ =
            List.map (fun (a, _) -> Mid.find a tvi) rule.R.rl_tyd in
          let typ = List.map (EcTypes.ty_subst ts) typ in

          let es = List.map (fun (a,_ty) ->
              let e = Mid.find a !e_pv in
              e
            ) rule.R.rl_evars in

          let mt = oget ~exn:NotReducible !sc_mt in

          let ps = List.map (fun id ->
              Mid.find id !p_pv
            ) rule.R.rl_pvars in

          let f =
            EcDecl.sc_instantiate
              rule.R.rl_tyd rule.R.rl_pvars rule.R.rl_evars
              typ mt ps es f in

          let subst =
            Mid.fold (fun x f s ->
                Fsubst.f_bind_local s x f
              ) !pv (Fsubst.f_subst_init ()) in
          Fsubst.f_subst subst (Fsubst.subst_tvar tvi f) in

      List.iter (fun cond ->
        if not (f_equal (simplify (subst cond)) f_true) then
          raise NotReducible)
        rule.R.rl_cond;

      Some (subst rule.R.rl_tg)

    with NotReducible -> None)
  rules)

(* -------------------------------------------------------------------- *)
let check_reduced hyps exn f f' =
  if is_alpha_eq hyps f f' then raise exn else f'

(* -------------------------------------------------------------------- *)
let reduce_quant ri _env hyps f =
  match f.f_node with
  | Fquant (Lforall as t, b, f1)
  | Fquant (Lexists as t, b, f1) when ri.logic = Some `Full ->
    let f' = match t with
      | Lforall -> f_forall_simpl b f1
      | Lexists -> f_exists_simpl b f1
      | Llambda -> assert false in
    check_reduced hyps needsubterm f f'
  | _ -> raise nohead

(* -------------------------------------------------------------------- *)
let reduce_logic ri env hyps f p args =
  let pcompat =
    match ri.logic with
    | Some `Full -> true
    | Some `ProductCompat -> false
    | None -> raise nohead
  in

  let f' =
    match op_kind p, args with
    | Some (`Imp), [f1;f2] when pcompat -> f_imp_simpl f1 f2
    | Some (`Iff), [f1;f2] when pcompat -> f_iff_simpl f1 f2

    | Some (`Not)      , [f1]    -> f_not_simpl f1
    | Some (`And `Asym), [f1;f2] -> f_anda_simpl f1 f2
    | Some (`Or  `Asym), [f1;f2] -> f_ora_simpl f1 f2
    | Some (`And `Sym ), [f1;f2] -> f_and_simpl f1 f2
    | Some (`Or  `Sym ), [f1;f2] -> f_or_simpl f1 f2
    | Some (`Int_le   ), [f1;f2] -> f_int_le_simpl f1 f2
    | Some (`Int_lt   ), [f1;f2] -> f_int_lt_simpl f1 f2
    | Some (`Real_le  ), [f1;f2] -> f_real_le_simpl f1 f2
    | Some (`Real_lt  ), [f1;f2] -> f_real_lt_simpl f1 f2
    | Some (`Int_add  ), [f1;f2] -> f_int_add_simpl f1 f2
    | Some (`Int_opp  ), [f]     -> f_int_opp_simpl f
    | Some (`Int_mul  ), [f1;f2] -> f_int_mul_simpl f1 f2
    | Some (`Int_edivz), [f1;f2] -> f_int_edivz_simpl f1 f2
    | Some (`Real_add ), [f1;f2] -> f_real_add_simpl f1 f2
    | Some (`Real_opp ), [f]     -> f_real_opp_simpl f
    | Some (`Real_mul ), [f1;f2] -> f_real_mul_simpl f1 f2
    | Some (`Real_inv ), [f]     -> f_real_inv_simpl f
    | Some (`Eq       ), [f1;f2] ->
      begin
        match fst_map f_node (destr_app f1), fst_map f_node (destr_app f2) with
        | (Fop (p1, _), args1), (Fop (p2, _), args2)
            when EcEnv.Op.is_dtype_ctor env p1
                 && EcEnv.Op.is_dtype_ctor env p2 ->

          let idx p =
            let idx = EcEnv.Op.by_path p env in
            snd (EcDecl.operator_as_ctor idx)
          in
          if   idx p1 <> idx p2
          then f_false
          else f_ands (List.map2 f_eq args1 args2)

        | (_, []), (_, [])
            when EqTest_i.for_type env f1.f_ty EcTypes.tunit
                 && EqTest_i.for_type env f2.f_ty EcTypes.tunit ->

          f_true

        | _ ->
          if   f_equal f1 f2 || is_alpha_eq hyps f1 f2
          then f_true
          else f_eq_simpl f1 f2
      end

    | _ -> raise nohead
  in
  check_reduced hyps needsubterm f f'

(* -------------------------------------------------------------------- *)
let reduce_delta ri env _hyps f =
  match f.f_node with
  | Fop (p, tys) when ri.delta_p p <> `No ->
      reduce_op ri env 0 p tys

  | Fapp ({ f_node = Fop (p, tys) }, args) when ri.delta_p p <> `No ->
      let op = reduce_op ri env (List.length args) p tys in
      f_app_simpl op args f.f_ty

  | _ -> raise nohead

(* -------------------------------------------------------------------- *)
let reduce_cost ri env coe =
  if not ri.cost then raise nohead;
  if EcCHoare.free_expr coe.coe_e then f_x0
  else match coe.coe_e.e_node with
    | Etuple es ->
      List.fold_left (fun acc e ->
          f_xadd acc (EcCHoare.cost_of_expr coe.coe_pre coe.coe_mem e))
        f_x1 es

    | Eop (p, _) when EcEnv.Op.is_dtype_ctor ~nargs:0 env p ->
      f_x1

    | Eapp ({e_node = Eop (p, _); }, es)
      when EcEnv.Op.is_dtype_ctor ~nargs:(List.length es) env p ->
      List.fold_left (fun acc e ->
          f_xadd acc (EcCHoare.cost_of_expr coe.coe_pre coe.coe_mem e))
        f_x1 es

    | Eif (c,l,r) ->
      (* Max upper-bounded by the sum. *)
      List.fold_left (fun acc e ->
          f_xadd acc (EcCHoare.cost_of_expr coe.coe_pre coe.coe_mem e))
        f_x1 [c; l; r]

    | Eproj (e,_) ->
      f_xadd f_x1 (EcCHoare.cost_of_expr coe.coe_pre coe.coe_mem e)

    | _ -> raise nohead



(* -------------------------------------------------------------------- *)
(* Perform one step of head reduction                                   *)
let reduce_head simplify ri env hyps f =
  match f.f_node with
    (* β-reduction *)
  | Fapp ({ f_node = Fquant (Llambda, _, _)}, _) when ri.beta ->
      f_betared f

    (* ζ-reduction *)
  | Flocal x -> reduce_local ri hyps x

    (* ζ-reduction *)
  | Fapp ({ f_node = Flocal x }, args) ->
      f_app_simpl (reduce_local ri hyps x) args f.f_ty

    (* ζ-reduction *)
  | Flet (LSymbol(x,_), e1, e2) when ri.zeta ->
      let s = EcSubst.add_flocal EcSubst.empty x e1 in
      EcSubst.subst_form s e2

    (* ι-reduction (let-tuple) *)
  | Flet (LTuple ids, e1, e2) when ri.iota ->
    if is_tuple e1 then
      let es = destr_tuple e1 in
      let s =
        List.fold_left2
          (fun s (x,_) e -> Fsubst.f_bind_local s x e)
          Fsubst.f_subst_id ids es
      in
        Fsubst.f_subst s e2
    else raise needsubterm

    (* ι-reduction (let-records) *)
  | Flet (LRecord (_, ids), f1, f2) when ri.iota ->
    if is_record env f1 then
      let args  = snd (EcFol.destr_app f1) in
      let subst =
        List.fold_left2 (fun subst (x, _) e ->
          match x with
          | None   -> subst
          | Some x -> Fsubst.f_bind_local subst x e)
          Fsubst.f_subst_id ids args
      in
        Fsubst.f_subst subst f2
    else raise nohead

    (* ι-reduction (records projection) *)
  | Fapp ({ f_node = Fop (p, _); }, args)
      when ri.iota && EcEnv.Op.is_projection env p ->
      begin match args with
      | mk :: args ->
        begin match mk.f_node with
        | Fapp ({ f_node = Fop (mkp, _) }, mkargs) ->
          if not (EcEnv.Op.is_record_ctor env mkp) then raise nohead;
          let v = oget (EcEnv.Op.by_path_opt p env) in
          let v = proj3_2 (EcDecl.operator_as_proj v) in
          let v = List.nth mkargs v in
          f_app v args f.f_ty

        | _ -> raise needsubterm
        end
      | _ -> raise nohead
      end

    (* ι-reduction (tuples projection) *)
  | Fproj(f1, i) when ri.iota ->
    check_reduced hyps needsubterm f (f_proj_simpl f1 i f.f_ty)

    (* ι-reduction (if-then-else) *)
  | Fif (f1, f2, f3) when ri.iota ->
    check_reduced hyps needsubterm f (f_if_simpl f1 f2 f3)

    (* ι-reduction (if-then-else) *)
  | Fmatch (c, bs, ty) when ri.iota -> begin
      let op, args = destr_app c in

        match op.f_node with
        | Fop (p, _) when EcEnv.Op.is_dtype_ctor env p ->
            let idx = EcEnv.Op.by_path p env in
            let idx = snd (EcDecl.operator_as_ctor idx) in
            let br  = oget (List.nth_opt bs idx) in
            f_app br args ty

        | _ -> raise needsubterm
    end

    (* ι-reduction (match-fix) *)
  | Fapp ({ f_node = Fop (p, tys); }, fargs)
      when ri.iota && EcEnv.Op.is_fix_def env p ->

      let op  = oget (EcEnv.Op.by_path_opt p env) in
      let fix = EcDecl.operator_as_fix op in

      if List.length fargs < snd (fix.EcDecl.opf_struct) then
        raise nohead;

      let fargs, eargs = List.split_at (snd (fix.EcDecl.opf_struct)) fargs in

      let args  = Array.of_list fargs in
      let pargs = List.fold_left (fun (opb, acc) v ->
             let v = args.(v) in
              match fst_map (fun x -> x.f_node) (EcFol.destr_app v) with
              | (Fop (p, _), cargs) when EcEnv.Op.is_dtype_ctor env p -> begin
                  let idx = EcEnv.Op.by_path p env in
                  let idx = snd (EcDecl.operator_as_ctor idx) in
                  match opb with
                  | EcDecl.OPB_Leaf   _  -> assert false
                  | EcDecl.OPB_Branch bs ->
                    ((Parray.get bs idx).EcDecl.opb_sub, cargs :: acc)
                end
              | _ -> raise needsubterm)
            (fix.EcDecl.opf_branches, []) (fst fix.EcDecl.opf_struct)
      in

      let pargs, (bds, body) =
        match pargs with
        | EcDecl.OPB_Leaf (bds, body), cargs -> (List.rev cargs, (bds, body))
        | _ -> assert false
      in

      let subst =
        List.fold_left2
          (fun subst (x, _) fa -> Fsubst.f_bind_local subst x fa)
          Fsubst.f_subst_id fix.EcDecl.opf_args fargs in

      let subst =
        List.fold_left2
          (fun subst bds cargs ->
            List.fold_left2
              (fun subst (x, _) fa -> Fsubst.f_bind_local subst x fa)
              subst bds cargs)
          subst bds pargs in

      let body = EcFol.form_of_expr EcFol.mhr body in
      let body =
        EcFol.Fsubst.subst_tvar
          (EcTypes.Tvar.init (List.map fst op.EcDecl.op_tparams) tys) body in

      f_app (Fsubst.f_subst subst body) eargs f.f_ty

    (* μ-reduction *)
  | Fglob (mp, m) when ri.modpath ->
    let f' = NormMp.norm_glob env m mp in
    if f_equal f f' then raise nohead else f'

    (* μ-reduction *)
  | Fpvar (pv, m) when ri.modpath ->
    let f' = f_pvar (NormMp.norm_pvar env pv) f.f_ty m in
    if f_equal f f' then raise nohead else f'

    (* η-reduction *)
  | Fquant (Llambda, [x, GTty _], { f_node = Fapp (fn, args) })
      when ri.eta && can_eta x (fn, args)
    -> f_app fn (List.take (List.length args - 1) args) f.f_ty

  | Fop _ -> reduce_delta ri env hyps f

  | Fapp({ f_node = Fop(p,_); }, args) -> begin
      try  reduce_logic ri env hyps f p args
      with NotRed kind1 ->
        try  reduce_user_gen simplify ri env hyps f
        with NotRed kind2 ->
          if kind1 = NoHead && kind2 = NoHead then reduce_delta ri env hyps f
          else raise needsubterm
    end

  | Fapp(_, _) -> raise needsubterm

  | Fquant((Lforall | Lexists), _, _) ->
    reduce_quant ri env hyps f

  | Fcoe coe -> begin
    try reduce_cost ri env coe with
      | NotRed _ -> reduce_user_gen simplify ri env hyps f
    end

  | _ -> raise nohead

let rec eta_norm f =
  match f.f_node with
  | Fquant (Llambda, [x, GTty _], { f_node = Fapp (fn, args) })
      when can_eta x (fn, args)
    -> eta_norm (f_app fn (List.take (List.length args - 1) args) f.f_ty)
  | _ -> f

(* -------------------------------------------------------------------- *)
type reduced =
  | Red of bool * form (* bool true => at least on head reduction has been done *)
  | Norm               (* The term is in weak_head normal from (no reduction under lambda *)
  | Unknown

module RedTbl : sig
  type t

  val init        : unit -> t
  val get         : t -> form -> reduced
  val set_reduced : t -> form -> form -> unit
  val set_sub     : t -> form -> form -> unit
  val set_norm    : t -> form -> unit
end = struct
  type t = reduced Hf.t

  let init () =
    Hf.create 1023

  let rec get redtbl f =
    match Hf.find redtbl f with
    | Red (h1, f1) as r -> begin
        match get redtbl f1 with
        | Red (h2,f2) as r1 ->
          let r1 = if h1 = h2 then r1 else Red (h1 || h2, f2) in
          Hf.replace redtbl f r1; r1
        | Norm | Unknown -> r
      end
    | (Norm | Unknown) as r -> r
    | exception Not_found -> Unknown

  let set_reduced redtbl f f' = Hf.replace redtbl f (Red (true, f'))
  let set_sub     redtbl f f' = Hf.replace redtbl f (Red (false, f'))
  let set_norm    redtbl f    = Hf.replace redtbl f Norm
end

type redtbl = RedTbl.t

(* -------------------------------------------------------------------- *)
type redinfo = {
  ri     : reduction_info;
  redtbl : redtbl;
  hyps   : LDecl.hyps;
}

(* -------------------------------------------------------------------- *)
let init_redinfo ri hyps =
  ({ ri; hyps; redtbl = RedTbl.init (); }, LDecl.toenv hyps)

(* -------------------------------------------------------------------- *)
let rec reduce_head_top (ri:redinfo) env ~onhead f =
  match RedTbl.get ri.redtbl f with
  | Norm    -> raise nohead
  | Red (h,f')  ->
    if h || not onhead then f'
    else reduce_head_top_force ri env onhead f'
  | Unknown -> reduce_head_top_force ri env onhead f

and reduce_head_top_force ri env onhead f =
  match reduce_head (whnf ri env) ri.ri env ri.hyps f with
  | f' ->
    RedTbl.set_reduced ri.redtbl f f'; f'

  | exception (NotRed NoHead) when is_tuple f && not onhead -> begin
      match reduce_head_sub ri env f with
      | f' -> f'
      | exception (NotRed _) -> RedTbl.set_norm ri.redtbl f; raise nohead
    end

  | exception (NotRed NeedSubTerm) -> begin
    match reduce_head_sub ri env f with
    | f ->
      if onhead then reduce_head_top ri env ~onhead f else f
    | exception (NotRed _) ->
      try reduce_delta ri.ri env ri.hyps f
      with NotRed _ -> RedTbl.set_norm ri.redtbl f; raise nohead
  end

and reduce_head_sub ri env f =
  let f' =
    match f.f_node with
    | Fapp({f_node = Fop _} as f1, args) ->
      f_app f1 (reduce_head_args ri env args) f.f_ty

    | Fapp (f1, args) -> begin
        match reduce_head_args ri env (f1::args) with
        | f1::args -> f_app f1 args f.f_ty
        | []       -> assert false
      end

    | Fquant ((Lforall | Lexists) as t, b, f1) ->
      let env = Mod.add_mod_binding b env in
      f_quant t b (reduce_head_top ri env ~onhead:false f1)

    | Flet(lp, f1, f2) ->
      curry (f_let lp) (as_seq2 (reduce_head_args ri env [f1;f2]))

    | Fproj(f1,i) ->
      f_proj (reduce_head_top ri env ~onhead:false f1) i f.f_ty

    | Fif (f1, f2, f3) ->
      curry3 f_if (as_seq3 (reduce_head_args ri env [f1; f2; f3]))

    | Fmatch (c, bs, tys) ->
      let c, bs =
        match reduce_head_args ri env (c :: bs) with
        | [] -> assert false
        | c :: bs -> (c, bs)
      in f_match c bs tys

    | Ftuple args ->
      f_tuple (reduce_head_args ri env args)

    | Fcoe coe ->
      let coe_pre = as_seq1 (reduce_head_args ri env [coe.coe_pre]) in
      f_coe_r { coe with coe_pre }

    | _ -> assert false

  in RedTbl.set_sub ri.redtbl f f'; f'

and reduce_head_args ri env args =
  match args with
  | [] -> raise nohead
  | a :: args ->
    try  reduce_head_top ri env ~onhead:false a :: args
    with NotRed _ -> a :: reduce_head_args ri env args

(* Performs head reduction when possible *)
and whnf ri env f =
  match reduce_head_top ri env ~onhead:true f with
  | f -> whnf ri env f
  | exception (NotRed _) -> f

(* -------------------------------------------------------------------- *)
let rec simplify ri env f =
  let f = whnf ri env f in
  match f.f_node with
  | FhoareF hf when ri.ri.modpath ->
      let hf_f = EcEnv.NormMp.norm_xfun env hf.hf_f in
      f_map (fun ty -> ty) (simplify ri env) (f_hoareF_r { hf with hf_f })

  | FbdHoareF hf when ri.ri.modpath ->
      let bhf_f = EcEnv.NormMp.norm_xfun env hf.bhf_f in
      f_map (fun ty -> ty) (simplify ri env) (f_bdHoareF_r { hf with bhf_f })

  | FcHoareF hf when ri.ri.modpath ->
      let chf_f = EcEnv.NormMp.norm_xfun env hf.chf_f in
      f_map (fun ty -> ty) (simplify ri env) (f_cHoareF_r { hf with chf_f })

  | FequivF ef when ri.ri.modpath ->
      let ef_fl = EcEnv.NormMp.norm_xfun env ef.ef_fl in
      let ef_fr = EcEnv.NormMp.norm_xfun env ef.ef_fr in
      f_map (fun ty -> ty) (simplify ri env) (f_equivF_r { ef with ef_fl; ef_fr; })

  | FeagerF eg when ri.ri.modpath ->
      let eg_fl = EcEnv.NormMp.norm_xfun env eg.eg_fl in
      let eg_fr = EcEnv.NormMp.norm_xfun env eg.eg_fr in
      f_map (fun ty -> ty) (simplify ri env) (f_eagerF_r { eg with eg_fl ; eg_fr; })

  | Fpr pr when ri.ri.modpath ->
      let pr_fun = EcEnv.NormMp.norm_xfun env pr.pr_fun in
      f_map (fun ty -> ty) (simplify ri env) (f_pr_r { pr with pr_fun })

  | Fquant (q, bd, f) ->
    let env = Mod.add_mod_binding bd env in
    f_quant q bd (simplify ri env f)

  | _ ->
    f_map (fun ty -> ty) (simplify ri env) f

let simplify ri hyps f =
  let ri, env = init_redinfo ri hyps in
  simplify ri env f

(* ----------------------------------------------------------------- *)
(* Checking convertibility                                           *)

let check_memenv env (x1,mt1) (x2,mt2) =
  EcMemory.mem_equal x1 x2 &&
    try check_memtype env mt1 mt2; true with NotConv -> false

(* -------------------------------------------------------------------- *)
type head_sub =
  | Zquant of quantif * bindings (* in reversed order *)
  | Zif
  | Zmatch of EcTypes.ty
  | Zlet   of lpattern
  | Zapp
  | Ztuple
  | Zproj  of int
  | Zhl    of form (* program logic predicates *)

type stk_elem = {
    se_h      : head_sub;
    se_common : form list;
    se_args1  : form list;
    se_args2  : form list;
    se_ty     : ty;
  }

let zpush se_h se_common se_args1 se_args2 se_ty stk =
  { se_h; se_common; se_args1; se_args2; se_ty} :: stk

(* FIXME normalize zquant *)

let zquant q bd ty stk = zpush (Zquant (q, bd)) [] [] [] ty stk
let zif args1 args2 ty stk = zpush Zif [] args1 args2 ty stk
let zmatch bsty args1 args2 ty stk = zpush (Zmatch bsty) [] args1 args2 ty stk
let zlet lp f1 f2 stk = zpush (Zlet lp) [] [f1] [f2] f1.f_ty stk

let zapp args1 args2 ty stk =
  match stk with
  | se::stk when se.se_h = Zapp && se.se_common = [] ->
    zpush Zapp [] (args1 @ se.se_args1) (args2 @ se.se_args2) se.se_ty stk
  | _ -> zpush Zapp [] args1 args2 ty stk

let ztuple args1 args2 ty stk = zpush Ztuple [] args1 args2 ty stk
let zproj i ty stk = zpush (Zproj i) [] [] [] ty stk
let zhl f fs1 fs2 stk = zpush (Zhl f) [] fs1 fs2 f.f_ty stk

let zpop ri side f hd =
  let args =
    match side with
    | `Left  -> hd.se_args1
    | `Right -> hd.se_args2 in
  let args = List.rev_append hd.se_common (f::args) in
  match hd.se_h, args with
  | Zquant(Llambda,bd), [f] when ri.ri.eta -> eta_norm (f_lambda bd f)

  | Zquant(q,bd), [f]  -> f_quant q bd f
  | Zif, [f1;f2;f3]    -> f_if f1 f2 f3
  | Zmatch ty, c :: bs -> f_match c bs ty
  | Zlet lp, [f1;f2]   -> f_let lp f1 f2
  | Zapp, f1::args     -> f_app f1 args hd.se_ty
  | Ztuple, args       -> f_tuple args
  | Zproj i, [f1]      -> f_proj f1 i hd.se_ty
  | Zhl {f_node = FhoareF hf}, [pr;po] ->
    f_hoareF_r {hf with hf_pr = pr; hf_po = po }
  | Zhl {f_node = FhoareS hs}, [pr;po] ->
    f_hoareS_r {hs with hs_pr = pr; hs_po = po }
  | Zhl {f_node = FbdHoareF hf}, [pr;po;bd] ->
    f_bdHoareF_r {hf with bhf_pr = pr; bhf_po = po; bhf_bd = bd}
  | Zhl {f_node = FbdHoareS hs}, [pr;po;bd] ->
    f_bdHoareS_r {hs with bhs_pr = pr; bhs_po = po; bhs_bd = bd}
  | Zhl {f_node = FequivF hf}, [pr;po] ->
    f_equivF_r {hf with ef_pr = pr; ef_po = po }
  | Zhl {f_node = FequivS hs}, [pr;po] ->
    f_equivS_r {hs with es_pr = pr; es_po = po }
  | Zhl {f_node = FeagerF hs}, [pr;po] ->
    f_eagerF_r {hs with eg_pr = pr; eg_po = po }
  | Zhl {f_node = Fpr hs}, [a;ev] ->
    f_pr_r {hs with pr_args = a; pr_event = ev }
  | Zhl {f_node = Fcoe hcoe}, [pre] ->
    f_coe_r {hcoe with coe_pre = pre}
  | Zhl {f_node = FcHoareF hfc}, chf_pr::chf_po::self_::pcalls -> (* FIXME *)
    let co, ca = List.split_at (List.length pcalls / 2) pcalls in
    let calls =
      List.map2
        (fun (xp, _) (cb_cost, cb_called) -> (xp, call_bound_r cb_cost cb_called))
        (Mx.bindings hfc.chf_co.c_calls) (List.combine co ca) in
    f_cHoareF_r { hfc with chf_pr; chf_po; chf_co = cost_r self_ (Mx.of_list calls) }
  | Zhl {f_node = FcHoareS hfs}, chs_pr::chs_po::self_::pcalls -> (* FIXME *)
    let co, ca = List.split_at (List.length pcalls / 2) pcalls in
    let calls =
      List.map2
        (fun (xp, _) (cb_cost, cb_called) -> (xp, call_bound_r cb_cost cb_called))
        (Mx.bindings hfs.chs_co.c_calls) (List.combine co ca) in
    f_cHoareS_r { hfs with chs_pr; chs_po; chs_co = cost_r self_ (Mx.of_list calls) }
  | _, _ -> assert false

(* -------------------------------------------------------------------- *)
let rec conv ri env f1 f2 stk =
  if f_equal f1 f2 then conv_next ri env f1 stk else
  match f1.f_node, f2.f_node with
  | Fquant (q1, bd1, f1'), Fquant(q2,bd2,f2') ->
    if q1 <> q2 then force_head_sub ri env f1 f2 stk
    else
      let env, bd, f1', f2' =
        check_bindings_conv ri env q1 bd1 bd2 f1' f2'
      in

      if bd = [] then force_head ri env f1 f2 stk
      else
        let x = conv ri env f1' f2' (zquant q1 (List.rev bd) f1.f_ty stk) in
        x

  | Fquant(Llambda, bd, f), _ -> begin
    match stk with
    | se::stk when se.se_h = Zapp && se.se_common = [] && ri.ri.beta ->
      let f1 = f_betared (zpop ri `Left  f1 se) in
      let f2 = zpop ri `Right f2 se in
      conv ri env f1 f2 stk
    | _ ->
      if ri.ri.eta then
        conv ri env f (eta_expand bd f2 f.f_ty) (zquant Llambda bd f1.f_ty stk)
      else force_head ri env f1 f2 stk
    end

  | _, Fquant(Llambda, bd, f) -> begin
    match stk with
    | se::stk when se.se_h = Zapp && se.se_common = [] && ri.ri.beta ->
      let f1 = zpop ri `Left  f1 se in
      let f2 = f_betared (zpop ri `Right f2 se) in
      conv ri env f1 f2 stk
    | _ ->
      if ri.ri.eta then
        conv ri env (eta_expand bd f1 f.f_ty) f (zquant Llambda bd f2.f_ty stk)
      else force_head ri env f1 f2 stk
    end

  | Fif(f11, f12, f13), Fif(f21,f22,f23) ->
    conv ri env f11 f21 (zif [f12;f13] [f22;f23] f1.f_ty stk)

  | Fmatch(c1,bs1,ty1), Fmatch(c2,bs2,ty2) when
          List.length bs1 = List.length bs2
       && EqTest_i.for_type env ty1 ty2
    -> conv ri env c1 c2 (zmatch ty1 bs1 bs2 f1.f_ty stk)

  | Flet(lp1,f11,f12), Flet(lp2,f21,f22) -> begin
    match check_lpattern env EcSubst.empty lp1 lp2 with
    | env, subst ->
      let f21, f22 = EcSubst.subst_form subst f21, EcSubst.subst_form subst f22 in
      conv ri env f11 f21 (zlet lp1 f12 f22 stk)
    | exception NotConv -> force_head ri env f1 f2 stk
    end

  | Fop(p1, ty1), Fop(p2,ty2)
      when EcPath.p_equal p1 p2 && List.all2 (EqTest_i.for_type env) ty1 ty2 ->
    conv_next ri env f1 stk

  | Fapp(f1', args1), Fapp(f2', args2)
      when EqTest_i.for_type env f1'.f_ty f2'.f_ty
        && List.length args1 = List.length args2 -> begin
    (* So that we do not unfold operators *)
    match f1'.f_node, f2'.f_node with
    | Fop(p1, _), Fop(p2, _) when EcPath.p_equal p1 p2 ->
      conv_next ri env f1' (zapp args1 args2 f1.f_ty stk)
    | _, _ ->
      conv ri env f1' f2' (zapp args1 args2 f1.f_ty stk)
    end

  | Ftuple [], Ftuple [] ->
    conv_next ri env f1 stk

  | Ftuple (f1'::args1), Ftuple(f2'::args2)
      when List.length args1 = List.length args2 ->
    conv ri env f1' f2' (ztuple args1 args2 f1.f_ty stk)

  | Fproj(f1', i1), Fproj(f2',i2) when i1 = i2 ->
    conv ri env f1' f2' (zproj i1 f1.f_ty stk)

  | Fpvar(pv1, m1), Fpvar(pv2, m2)
      when EcEnv.NormMp.pv_equal env pv1 pv2 && EcMemory.mem_equal m1 m2 ->
      conv_next ri env f1 stk

  | Fglob (m1, mem1), Fglob (m2, mem2)
      when
        EcPath.m_equal
          (EcEnv.NormMp.norm_mpath env m1)
          (EcEnv.NormMp.norm_mpath env m2)
        && EcMemory.mem_equal mem1 mem2 ->
      conv_next ri env f1 stk

  | FhoareF hf1, FhoareF hf2 when EqTest_i.for_xp env hf1.hf_f hf2.hf_f ->
    conv ri env hf1.hf_pr hf2.hf_pr (zhl f1 [hf1.hf_po] [hf2.hf_po] stk)

  | FhoareS hs1, FhoareS hs2
      when EqTest_i.for_stmt env hs1.hs_s hs2.hs_s ->
    conv ri env hs1.hs_pr hs2.hs_pr (zhl f1 [hs1.hs_po] [hs2.hs_po] stk)

  | FbdHoareF hf1, FbdHoareF hf2
      when EqTest_i.for_xp env hf1.bhf_f hf2.bhf_f && hf1.bhf_cmp = hf2.bhf_cmp  ->
    conv ri env hf1.bhf_pr hf2.bhf_pr
      (zhl f1 [hf1.bhf_po;hf1.bhf_bd] [hf2.bhf_po; hf2.bhf_bd] stk)

  | FbdHoareS hs1, FbdHoareS hs2
      when EqTest_i.for_stmt env hs1.bhs_s hs2.bhs_s
        && hs1.bhs_cmp = hs2.bhs_cmp ->
    conv ri env hs1.bhs_pr hs2.bhs_pr
      (zhl f1 [hs1.bhs_po;hs1.bhs_bd] [hs2.bhs_po; hs2.bhs_bd] stk)

  | FcHoareF chf1, FcHoareF chf2
     when EqTest_i.for_xp env chf1.chf_f chf2.chf_f ->
     begin match check_cost_l env EcSubst.empty chf1.chf_co chf2.chf_co with
       | fs ->
         let fs1, fs2 = List.split fs in
         conv ri env chf1.chf_pr chf2.chf_pr
           (zhl f1 (chf1.chf_po :: fs1) (chf2.chf_po :: fs2) stk)
       | exception NotConv -> force_head ri env f1 f2 stk
     end

  | FcHoareS chs1, FcHoareS chs2
     when EqTest_i.for_stmt env chs1.chs_s chs2.chs_s ->
     begin match check_cost_l env EcSubst.empty chs1.chs_co chs2.chs_co with
       | fs ->
         let fs1, fs2 = List.split fs in
         conv ri env chs1.chs_pr chs2.chs_pr
           (zhl f1 (chs1.chs_po :: fs1) (chs2.chs_po :: fs2) stk)
       | exception NotConv -> force_head ri env f1 f2 stk
     end

  | FequivF ef1, FequivF ef2
      when EqTest_i.for_xp env ef1.ef_fl ef2.ef_fl
        && EqTest_i.for_xp env ef1.ef_fr ef2.ef_fr ->
    conv ri env ef1.ef_pr ef2.ef_pr (zhl f1 [ef1.ef_po] [ef2.ef_po] stk)

  | FequivS es1, FequivS es2
      when EqTest_i.for_stmt env es1.es_sl es2.es_sl
        && EqTest_i.for_stmt env es1.es_sr es2.es_sr ->
    conv ri env es1.es_pr es2.es_pr (zhl f1 [es1.es_po] [es2.es_po] stk)

  | FeagerF eg1, FeagerF eg2 ->
    if    EqTest_i.for_xp env eg1.eg_fl eg2.eg_fl
       && EqTest_i.for_xp env eg1.eg_fr eg2.eg_fr
       && EqTest_i.for_stmt env eg1.eg_sl eg2.eg_sl
       && EqTest_i.for_stmt env eg1.eg_sr eg2.eg_sr then
      conv ri env eg1.eg_pr eg2.eg_pr (zhl f1 [eg1.eg_po] [eg2.eg_po] stk)
    else
      force_head ri env f1 f2 stk

  | Fpr pr1, Fpr pr2 ->
    if EcMemory.mem_equal pr1.pr_mem pr2.pr_mem &&
         EqTest_i.for_xp env pr1.pr_fun pr2.pr_fun then
      conv ri env pr1.pr_args pr2.pr_args (zhl f1 [pr1.pr_event] [pr2.pr_event] stk)
    else
      force_head ri env f1 f2 stk

  | Fcoe coe1, Fcoe coe2 when is_alpha_eq_e env coe1.coe_e coe2.coe_e ->
    let bd1 = fst coe1.coe_mem, GTmem (snd coe1.coe_mem) in
    let bd2 = fst coe2.coe_mem, GTmem (snd coe2.coe_mem) in
    let env, bd, f1', f2' =
      check_bindings_conv ri env Lforall [bd1] [bd2] coe1.coe_pre coe2.coe_pre
    in
    if bd = [] then force_head ri env f1 f2 stk
    else conv ri env f1' f2' (zhl f1 [] [] stk)

  | _, _ -> force_head ri env f1 f2 stk


and check_bindings_conv ri env q bd1 bd2 f1 f2 =
  let test env subst f1 f2 =
    let f2 = EcSubst.subst_form subst f2 in
    conv ri env f1 f2 []
  in

  let rec aux es bd bd1 bd2 =
    match bd1, bd2 with
    | b1::bd1', b2::bd2' ->
      begin match check_binding test es b1 b2 with
      | es -> aux es (b1::bd) bd1' bd2'
      | exception NotConv -> es, bd, bd1, bd2
      end
    | _, _ -> es, bd, bd1, bd2 in
  let (env, subst), bd, bd1, bd2 = aux (env, EcSubst.empty) [] bd1 bd2 in
  env, bd, f_quant q bd1 f1, EcSubst.subst_form subst (f_quant q bd2 f2)

(* -------------------------------------------------------------------- *)
and conv_next ri env f stk =
  match stk with
  | [] -> true
  | hd::stk ->
    match hd.se_args1, hd.se_args2 with
    | [], [] ->
      let f1 = zpop ri `Left f hd in
      conv_next ri env f1 stk
    | f1::args1, f2::args2 ->
      let hd = { hd with se_common = f::hd.se_common;
                         se_args1  = args1;
                         se_args2  = args2; } in
      conv ri env f1 f2 (hd::stk)
    | _, _ -> assert false

and force_head ri env f1 f2 stk =
  (* FIXME add oracle to decide what to do *)
  let reduce_first side f1 f2 stk =
    let f = if side = `Left then f1 else f2 in
    match stk with
    | se::stk when is_op f && se.se_h = Zapp && se.se_common = [] ->
      let f1 = zpop ri `Left  f1 se in
      let f2 = zpop ri `Right f2 se in
      f1, f2, stk
    | _ -> f1, f2, stk in

  let f1', f2', stk' = reduce_first `Left f1 f2 stk in
  match reduce_head_top ri env ~onhead:true f1' with
  | f1' -> conv ri env f1' f2' stk'
  | exception (NotRed _) ->
    let f1', f2', stk' = reduce_first `Right f1 f2 stk in
    match reduce_head_top ri env ~onhead:true f2' with
    | f2' -> conv ri env f1' f2' stk'
    | exception (NotRed _) ->
      force_head_sub ri env f1 f2 stk

and force_head_sub ri env f1 f2 stk =
  match stk with
  | [] -> false
  | hd::stk ->
    let f1 = zpop ri `Left  f1 hd in
    let f2 = zpop ri `Right f2 hd in
    force_head ri env f1 f2 stk

(* -------------------------------------------------------------------- *)
let reduce_user_gen simplify ri env hyps f =
  try reduce_user_gen simplify ri env hyps f
  with NotRed _ -> raise NotReducible

(* -------------------------------------------------------------------- *)
let reduce_logic ri env hyps f = match f.f_node with
  | Fapp({ f_node = Fop(p,_); }, args) -> begin
      try reduce_logic ri env hyps f p args with
      | NotRed _ -> raise NotReducible
    end
  | _ -> raise NotReducible

(* -------------------------------------------------------------------- *)
let reduce_cost ri env coe =
  try reduce_cost ri env coe with
  | NotRed _ -> raise NotReducible

(* -------------------------------------------------------------------- *)
let is_conv ?(ri = full_red) hyps f1 f2 =
  if f_equal f1 f2 then true
  else
    let ri, env = init_redinfo ri hyps in
    if EqTest_i.for_type env f1.f_ty f2.f_ty then conv ri env f1 f2 []
    else false

let check_conv ?ri hyps f1 f2 =
  if is_conv ?ri hyps f1 f2 then ()
  else raise (IncompatibleForm ((LDecl.toenv hyps), (f1, f2)))

(* -------------------------------------------------------------------- *)
let h_red ri hyps f =
  try
    let ri, env = init_redinfo ri hyps in
    reduce_head_top ri env ~onhead:true f
  with NotRed _ -> raise NotReducible

let h_red_opt ri hyps f =
  try Some (h_red ri hyps f)
  with NotReducible -> None

(* -------------------------------------------------------------------- *)
type xconv = [`Eq | `AlphaEq | `Conv]

let xconv (mode : xconv) hyps =
  match mode with
  | `Eq      -> f_equal
  | `AlphaEq -> is_alpha_eq hyps
  | `Conv    -> is_conv hyps


(* -------------------------------------------------------------------- *)
module User = struct
  type options = EcTheory.rule_option

  type error =
    | MissingVarInLhs   of EcIdent.t
    | MissingEVarInLhs  of EcIdent.t
    | MissingTyVarInLhs of EcIdent.t
    | MissingPVarInLhs  of EcIdent.t
    | NotAnEq
    | NotFirstOrder
    | RuleDependsOnMemOrModule
    | HeadedByVar

  exception InvalidUserRule of error

  module R = EcTheory

  type rule = EcEnv.Reduction.rule

  let get_spec = function
    | `Ax ax -> ax.EcDecl.ax_spec
    | `Sc sc -> sc.EcDecl.axs_spec

  let get_typ = function
    | `Ax ax -> ax.EcDecl.ax_tparams
    | `Sc sc -> sc.EcDecl.axs_tparams

  type compile_st = { cst_ty_vs        : Sid.t;
                      cst_f_vs         : Sid.t;
                      cst_cost_pre_vs  : Sid.t;
                      cst_cost_expr_vs : Sid.t; }

  let empty_cst = { cst_ty_vs        = Sid.empty;
                    cst_f_vs         = Sid.empty;
                    cst_cost_pre_vs  = Sid.empty;
                    cst_cost_expr_vs = Sid.empty; }

  let compile ~opts ~prio (env : EcEnv.env) mode p =
    let simp =
      if opts.EcTheory.ur_delta then
        let hyps = EcEnv.LDecl.init env [] in
        fun f -> odfl f (h_red_opt delta hyps f)
      else fun f -> f in

    let ax_sc = match mode with
      | `Ax -> `Ax (EcEnv.Ax.by_path p env)
      | `Sc -> `Sc (EcEnv.Schema.by_path p env) in
    let bds, rl = EcFol.decompose_forall (simp (get_spec ax_sc)) in

    let bds =
      let filter = function
        | (x, GTty ty) -> (x, ty)
        | _ -> raise (InvalidUserRule RuleDependsOnMemOrModule)
      in List.map filter bds in

    let pbds, ebds = match ax_sc with
      | `Ax _  -> [],[]
      | `Sc sc -> sc.EcDecl.axs_pparams, sc.EcDecl.axs_params in

    let lhs, rhs, conds =
      try
        let rec doit conds f =
          match sform_of_form (simp f) with
          | SFimp (f1, f2) -> doit (f1 :: conds) f2
          | SFiff (f1, f2)
          | SFeq  (f1, f2) -> (f1, f2, List.rev conds)
          | _ when ty_equal tbool (EcEnv.ty_hnorm f.f_ty env) ->
            (f, f_true, List.rev conds)
          | _ -> raise (InvalidUserRule NotAnEq)
        in doit [] rl

      with InvalidUserRule NotAnEq
        when opts.EcTheory.ur_eqtrue &&
             ty_equal tbool (EcEnv.ty_hnorm rl.f_ty env)
        -> (rl, f_true, List.rev [])
    in

    let rule =
      let rec rule (f : form) : EcTheory.rule_pattern =
        match EcFol.destr_app f with
        | { f_node = Fop (p, tys) }, args ->
            R.Rule (`Op (p, tys), List.map rule args)
        | { f_node = Ftuple args }, [] ->
            R.Rule (`Tuple, List.map rule args)
        | { f_node = Fint i }, [] ->
            R.Int i
        | { f_node = Flocal x }, [] ->
            R.Var x
        | { f_node = Fcoe coe }, [] ->
            let inner_e = e_rule coe.coe_e in
            let inner_pre = rule coe.coe_pre in
            R.Cost (coe.coe_mem, inner_pre, inner_e)
        | _ -> raise (InvalidUserRule NotFirstOrder)

      and e_rule (e : expr) =
        (* The chosen memory does not matter here (we pick [mhr] by default). *)
        rule (form_of_expr mhr e)

      in rule lhs in

    let cst =
      let rec doit ~cmode cst = function
        | R.Var x ->
          (* Depending on the mode, we add the variable to the corresp. set. *)
          begin match cmode with
            | UR_Form ->
              { cst with cst_f_vs = Sid.add x cst.cst_f_vs }
            | UR_CostPre _ ->
              { cst with cst_cost_pre_vs = Sid.add x cst.cst_cost_pre_vs }
            | UR_CostExpr _ ->
              { cst with cst_cost_expr_vs = Sid.add x cst.cst_cost_expr_vs } end

        | R.Int _ -> cst

        | R.Rule (op, args) ->
            let ltyvars =
              match op with
              | `Op (_, tys) ->
                List.fold_left (
                    let rec doit ltyvars = function
                      | { ty_node = Tvar a } -> Sid.add a ltyvars
                      | _ as ty -> ty_fold doit ltyvars ty in doit)
                  cst.cst_ty_vs tys
              | `Tuple -> cst.cst_ty_vs in
            let cst = {cst with cst_ty_vs = ltyvars } in
            List.fold_left (doit ~cmode) cst args

        | R.Cost (menv, pre, expr) ->
          let mhr = fst menv in
          let cst = doit ~cmode:(UR_CostExpr mhr) cst expr in
          doit ~cmode:(UR_CostPre mhr) cst pre

      in doit ~cmode:UR_Form empty_cst rule in


    let s_bds   = Sid.of_list (List.map fst bds)
    and s_ebds  = Sid.of_list (List.map fst ebds)
    and s_pbds  = Sid.of_list pbds
    and s_tybds = Sid.of_list (List.map fst (get_typ ax_sc)) in

    (* Variables appearing in types, cost expressions and formulas are
       always, respectively, type, expression and formula variables. *)
    let lvars = cst.cst_f_vs
    and ltyvars = cst.cst_ty_vs
    and levars = cst.cst_cost_expr_vs
    and lpvars = Sid.empty in
    (* Variables appearing in cost preconditions can be anything. *)
    let lvars, levars, lpvars =
      Sid.fold (fun id (lvars, levars, lpvars) ->
          if Sid.mem id s_ebds
          then (lvars, Sid.add id levars, lpvars)
          else if Sid.mem id s_pbds
          then (lvars, levars, Sid.add id lpvars)
          else (Sid.add id lvars, levars, lpvars) (* default to formula a var *)
        ) cst.cst_cost_pre_vs (lvars, levars, lpvars) in

    (* Sanity check *)
    assert (Sid.disjoint lvars   ltyvars &&
            Sid.disjoint lvars   levars &&
            Sid.disjoint lvars   lpvars &&
            Sid.disjoint ltyvars levars &&
            Sid.disjoint ltyvars lpvars &&
            Sid.disjoint levars  lpvars );

    (* We check that the binded variables all appear in the lhs.
       This ensures that, when applying the rule, we can infer how to
       instantiate the axiom or schema by matching with the lhs. *)
    let mvars   = Sid.diff s_bds lvars in
    let mevars  = Sid.diff s_ebds levars in
    let mtyvars = Sid.diff s_tybds ltyvars in
    let mpvars  = Sid.diff s_pbds lpvars in

    if not (Sid.is_empty mvars) then
      raise (InvalidUserRule (MissingVarInLhs (Sid.choose mvars)));
    if not (Sid.is_empty mevars) then
      raise (InvalidUserRule (MissingEVarInLhs (Sid.choose mevars)));
    if not (Sid.is_empty mtyvars) then
      raise (InvalidUserRule (MissingTyVarInLhs (Sid.choose mtyvars)));
    if not (Sid.is_empty mpvars) then
      raise (InvalidUserRule (MissingPVarInLhs (Sid.choose mpvars)));

    begin match rule with
    | R.Var _ -> raise (InvalidUserRule (HeadedByVar));
    | _       -> () end;

    R.{ rl_tyd   = get_typ ax_sc;
        rl_vars  = bds;
        rl_evars = ebds;
        rl_pvars = pbds;
        rl_cond  = conds;
        rl_ptn   = rule;
        rl_tg    = rhs;
        rl_prio  = prio; }

end

exception OpNotConv

let error_body b =
  if not b then raise OpNotConv

let conv_expr (env:env) s e1 e2 =
  let f1 = form_of_expr mhr e1 in
  let f2 = form_of_expr mhr e2 in
  error_body (is_conv (LDecl.init env []) f1 (EcSubst.subst_form s f2))

let get_open_oper env p tys =
  let oper = Op.by_path p env in
  let _, okind = EcSubst.open_oper oper tys in
  match okind with
  | OB_oper (Some ob) -> ob
  | _ -> raise OpNotConv

let check_bindings exn tparams env s bd1 bd2 =
  let test env s f1 f2 =
    let f2 = EcSubst.subst_form s f2 in
    is_conv (LDecl.init env tparams) f1 f2
  in

  try check_bindings test env s bd1 bd2
  with NotConv -> raise exn

let rec conv_oper env ob1 ob2 =
  match ob1, ob2 with
  | OP_Plain(f1,_), OP_Plain(f2,_)  ->
    error_body (is_conv (LDecl.init env []) f1 f2)
  | OP_Plain({f_node = Fop(p,tys)},_), _ ->
    let ob1 = get_open_oper env p tys  in
    conv_oper env ob1 ob2
  | _, OP_Plain({f_node = Fop(p,tys)}, _) ->
    let ob2 = get_open_oper env p tys in
    conv_oper env ob1 ob2
  | OP_Constr(p1,i1), OP_Constr(p2,i2) ->
    error_body (EcPath.p_equal p1 p2 && i1 = i2)
  | OP_Record p1, OP_Record p2 ->
    error_body (EcPath.p_equal p1 p2)
  | OP_Proj(p1,i11,i12), OP_Proj(p2,i21,i22) ->
    error_body (EcPath.p_equal p1 p2 && i11 = i21 && i12 = i22)
  | OP_Fix f1, OP_Fix f2 ->
    conv_opfix env f1 f2
  | OP_TC, OP_TC -> ()
  | _, _ -> raise OpNotConv

and conv_opfix env f1 f2 =
  let s = conv_params env EcSubst.empty f1.opf_args f2.opf_args in
  error_body (EqTest_i.for_type env f1.opf_resty f2.opf_resty);
  error_body (f1.opf_struct = f2.opf_struct);
  conv_opbranches env s f1.opf_branches f2.opf_branches

and conv_params env s p1 p2 =
  error_body (List.length p1 = List.length p2);
  let doit s (id1,ty1) (id2,ty2) =
    error_body (EqTest_i.for_type env ty1 ty2);
    EcSubst.add_flocal s id2 (f_local id1 ty1) in
  List.fold_left2 doit s p1 p2

and conv_opbranches env s ob1 ob2 =
  match ob1, ob2 with
  | OPB_Leaf(d1,e1), OPB_Leaf(d2,e2) ->
    error_body (List.length d1 = List.length d2);
    let s =
      List.fold_left2 (conv_params env) s d1 d2 in
    conv_expr env s e1 e2

  | OPB_Branch obs1, OPB_Branch obs2 ->
    error_body (Parray.length obs1 = Parray.length obs2);
    Parray.iter2 (conv_opbranch env s) obs1 obs2
  | _, _ -> raise OpNotConv

and conv_opbranch env s ob1 ob2 =
  error_body (EcPath.p_equal (fst ob1.opb_ctor) (fst ob2.opb_ctor));
  error_body (snd ob1.opb_ctor = snd ob2.opb_ctor);
  conv_opbranches env s ob1.opb_sub ob2.opb_sub

let get_open_pred env p tys =
  let oper = Op.by_path p env in
  let _, okind = EcSubst.open_oper oper tys in
  match okind with
  | OB_pred (Some pb) -> pb
  | _ -> raise OpNotConv

let rec conv_pred env pb1 pb2 =
  match pb1, pb2 with
  | PR_Plain f1, PR_Plain f2 -> error_body (is_conv (LDecl.init env []) f1 f2)
  | PR_Plain {f_node = Fop(p,tys)}, _ ->
    let pb1 = get_open_pred env p tys  in
    conv_pred env pb1 pb2
  | _, PR_Plain {f_node = Fop(p,tys)} ->
    let pb2 = get_open_pred env p tys  in
    conv_pred env pb1 pb2
  | PR_Ind pr1, PR_Ind pr2 ->
    conv_ind env pr1 pr2
  | _, _ -> raise OpNotConv

and conv_ind env pi1 pi2 =
  let s = conv_params env EcSubst.empty pi1.pri_args pi2.pri_args in
  error_body (List.length pi1.pri_ctors = List.length pi2.pri_ctors);
  List.iter2 (conv_prctor env s) pi1.pri_ctors pi2.pri_ctors

and conv_prctor env s prc1 prc2 =
  error_body (EcSymbols.sym_equal prc1.prc_ctor prc2.prc_ctor);
  (* FIXME:MERGE-CODE tparams=[]? *)
  let env, s = check_bindings OpNotConv [] env s prc1.prc_bds prc2.prc_bds in
  error_body (List.length prc1.prc_spec = List.length prc2.prc_spec);
  let doit f1 f2 =
    error_body (is_conv (LDecl.init env []) f1 (EcSubst.subst_form s f2)) in
  List.iter2 doit prc1.prc_spec prc2.prc_spec

let conv_nott env nb1 nb2 =
  let s = conv_params env EcSubst.empty nb1.ont_args nb2.ont_args in
  (* We do not check ont_resty because it is redundant *)
  conv_expr env s nb1.ont_body nb2.ont_body

let conv_operator env oper1 oper2 =
  let open EcDecl in
  let params = oper1.op_tparams in
  error_body (List.length params = List.length oper2.op_tparams);
  let oty1, okind1 = oper1.op_ty, oper2.op_kind in
  let tparams = List.map (fun (id,_) -> tvar id) params in
  let oty2, okind2 = EcSubst.open_oper oper2 tparams in
  error_body (EqTest_i.for_type env oty1 oty2);
  let hyps = EcEnv.LDecl.init env params in
  let env  = EcEnv.LDecl.toenv hyps in
  match okind1, okind2 with
  | OB_oper None      , OB_oper None       -> ()
  | OB_pred None      , OB_pred None       -> ()
  | OB_oper (Some ob1), OB_oper (Some ob2) -> conv_oper env ob1 ob2
  | OB_pred (Some pb1), OB_pred (Some pb2) -> conv_pred env pb1 pb2
  | OB_nott nb1       , OB_nott nb2        -> conv_nott env nb1 nb2
  | _                 , _                  -> raise OpNotConv

(* -------------------------------------------------------------------- *)
module EqTest = struct
  include EqTest_base

  include EqMod_base(struct
    let for_expr env ~norm:_ alpha e1 e2 =
      let convert e =
        let f = form_of_expr mhr e in

        if Mid.is_empty alpha then f else

        let subst =
          Mid.fold
            (fun x (y, ty) subst ->
              Fsubst.f_bind_local subst x (f_local y ty))
          alpha Fsubst.f_subst_id

        in Fsubst.f_subst subst f in

      let f1 = convert e1 in
      let f2 = convert e2 in

      is_conv (LDecl.init env []) f1 f2
   end)

  let for_pv    = fun env ?(norm = true) -> for_pv    env ~norm
  let for_lv    = fun env ?(norm = true) -> for_lv    env ~norm
  let for_xp    = fun env ?(norm = true) -> for_xp    env ~norm
  let for_mp    = fun env ?(norm = true) -> for_mp    env ~norm
  let for_instr = fun env ?(alpha = Mid.empty) ?(norm = true) -> for_instr env alpha ~norm
  let for_stmt  = fun env ?(alpha = Mid.empty) ?(norm = true) -> for_stmt  env alpha ~norm
  let for_expr  = fun env ?(alpha = Mid.empty) ?(norm = true) -> for_expr  env alpha ~norm

  let for_msig  = fun env ?(norm = true) -> for_module_sig  env ~norm
  let for_mexpr = fun env ?(norm = true) ?(body = true) -> for_module_expr env ~norm ~body
end
