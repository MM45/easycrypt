(* -------------------------------------------------------------------- *)
open EcUtils
open EcParsetree
open EcFol
open EcCoreGoal.FApi

(* -------------------------------------------------------------------- *)
val t_hoare_app   : int -> form -> backward
val t_bdhoare_app : int -> form tuple6 -> backward
val t_equiv_app   : int * int -> form -> backward

(* -------------------------------------------------------------------- *)
val process_app : tac_dir -> int doption -> pformula -> p_app_bd_info -> backward
