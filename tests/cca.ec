module type I = { 
  fun f() : unit
  fun init () : unit 
}.

module type IF (X:I) = { 
  fun init() : unit { X.init }
}.

module F(X:I) : IF(X), I = { 
   fun f() : unit = { X.f(); }
   fun init() : unit = { X.init();}
}.

module type Adv = {
  fun a (x:int) : int {} 
}.

module Test (A:Adv) = { 
  fun main(x:int) : int = { 
    var r : int;
    r  = A.a(x);
    return r;
  }
}.

module A : Adv = {
  fun a (x:int) : int = { return x; }
}.

module M = Test(A).

lemma foo : 
  forall (A<:Adv {Test}), 
    equiv [ Test(A).main ~ Test(A).main : 
         x{1} = x{2} /\ (glob A){1} = (glob A){2} ==> 
         res{1} = res{2} /\  (glob A){1} = (glob A){2} ].
proof.
 intros A.
 fun.
 call (x{1} = x{2} /\ (glob A){1} = (glob A){2}) 
      (res{1} = res{2} /\  (glob A){1} = (glob A){2}).
 fun true;try (simplify;split).
 skip;simplify. (* Il y a un bug : les variables sont des fois avec les
                   arguments des foncteurs d'autres fois non *)
 smt.
save.

module type IO = { 
  fun h (x:int) : int {}
}.

module type Adv' (O:IO) = { 
  fun a (x:int) : int { O.h } (* check that the oracle are disjoint *)
}.

module G (B:Adv') = {

  module O : IO = { 
    fun h (x:int) : int = {
      return x;
    }
  }

  module A1 = B(O) 

  fun main (x:int) : int = { 
    var r : int;
    r  = A1.a(x); 
    return r; 
  } 
}.

(* module F1 (B:Adv') = { 
  module A1 = B(G.O)
}.
*)

lemma foo' : 
  forall (A<:Adv' {G}), 
    equiv [ G(A).main ~ G(A).main : 
         x{1} = x{2} /\ (glob A){1} = (glob A){2} ==> 
         res{1} = res{2} /\  (glob A){1} = (glob A){2} ].
proof.
intros A. 
 fun.
 call (x{1} = x{2} /\ (glob A){1} = (glob A){2} /\ true) 
      (res{1} = res{2} /\ (glob A){1} = (glob A){2} /\ true).
 fun true;try smt.
 fun.
 skip;smt.
 skip;smt.
save.

module A' (O:IO) : Adv'(O) = { 
  fun a (x:int) : int = {
    var r : int;
    r  = O.h(x);
    return r;
  }
}.

lemma foo1 :
   equiv [ G(A').main ~ G(A').main : 
           x{1} = x{2} /\ (glob A'){1} = (glob A'){2} ==> 
           res{1} = res{2} /\  (glob A'){1} = (glob A'){2} ].
proof.
 apply (foo' (<:A')).
save.


lemma foo2 : forall (x:int) &m1 &m2, 
     Pr[G(A').main(x) @ &m1 : res = 0] = Pr[G(A').main(x) @ &m1 : res = 0].
proof.
 intros xv &m1 &m2.
 equiv_deno (_ : x{1} = x{2} /\ (glob A'){1} = (glob A'){2} ==> 
                 res{1} = res{2} /\  (glob A'){1} = (glob A'){2}).
 apply foo1.
 simplify;smt.
 smt.
save.

(*






type from.
type to.

module type Ihash = {
  fun init () : unit
  fun hash (x:from) : to 
}.

type skey.
type pkey.
type message.
type cipher.

require import Option.
require import List.
module type Ischeme (H:Ihash) = {
  fun gen()                   : pkey * skey     {H.hash}
  fun enc(pk:pkey, m:message) : cipher          {H.hash}
  fun dec(sk:skey, c:cipher)  : message option  {H.hash} 
}.

module type Icca_oracles = {
  fun hash (x:from)   : to
  fun dec1  (c:cipher) : message option
  fun dec2  (c:cipher) : message option
}.

module type Iadv (O:Icca_oracles) = {
  fun a1 (pk:pkey)  : message * message { O.hash O.dec1 }
  fun a2 (c:cipher) : bool              { O.hash O.dec2 }
}.

module CCA (H:Ihash, S:Ischeme, A:Iadv) = {
  var hlog    : from list
  var dec_log : cipher list
  var pk:pkey
  var sk:skey

  module S = S(H)

  module O = {

    fun hash (x:from) : to = { 
      var r : to;
      r  = H.hash(x);
      hlog = x::hlog;
      return r;
    }

    fun dec1 (c:cipher) : message option = {
      var r : message option;
      r  = S.dec(sk, c);
      return r;
    }

    fun dec2 (c:cipher) : message option = {
      var r : message option;
      dec_log = c::dec_log;
      r  = S.dec(sk,c);
      return r;
    }      
  }

  module A = A(O)

  var cs : cipher

  fun main () : bool = {
    var m0 : message;
    var m1 : message;
    var b  : bool;
    var b' : bool;
    H.init();
    hlog    = []
    dec_log = [];
    (pk,sk)  = S.gen();
    (m1,m0)  = A.a1(pk);
    cs       = S.enc(pk, b ? m1 : m0);
    b'       = A.a2(cs);
    return b = b';
  }
    
}.
*)