require import Int.
require import Real.
require import FSet.

(** Minimalist group theory with only needed components **)
theory Group.
  type group.

  const q: int.
  const g: group.
  axiom q_pos: 0 < q.

  op ( * ): group -> group -> group.
  op ( ^ ): group -> int -> group.

  axiom pow_mult (x y:int): (g ^ x) ^ y = g ^ (x * y). 
  axiom pow_plus (x y:int): (g ^ x) * (g ^ y) = g ^ (x + y).
end Group.

(** Computational Diffie-Hellman problem **)
theory CDH.
  clone import Group.

  module type Adversary = {
    proc solve(gx gy:group): group
  }.

  module CDH (A:Adversary) = {
    proc main(): bool = {
      var x, y, r;

      x = $[0..q-1];
      y = $[0..q-1];
      r = A.solve(g ^ x, g ^ y);
      return (r = g ^ (x * y));
    }
  }.
end CDH.

(** Set version of the Computational Diffie-Hellman problem **)
theory Set_CDH.
  clone (*--*) Group.
  clone (*--*) CDH with
    theory Group = Group.
  import CDH.Group.

  const n: int.

  module type Adversary = {
    proc solve(gx:group, gy:group): group set
  }.

  module SCDH (B:Adversary) = {
    proc main(): bool = {
      var x, y, s;

      x = $[0..q-1];
      y = $[0..q-1];
      s = B.solve(g ^ x, g ^ y);
      return (mem (g ^ (x * y)) s /\ card s <= n);
    }
  }.

  module CDH_from_SCDH (A:Adversary): CDH.Adversary = {
    proc solve(gx:group, gy:group): group = {
      var s, x;

      s = A.solve(gx, gy);
      x = $Duni.duni s;
      return x;
    }
  }.

  (** Naive reduction to CDH **)
  section.
    declare module A: Adversary.

    local module SCDH' = {
      var x, y: int

      proc aux(): group set = {
        var s;

        x = $[0..q-1];
        y = $[0..q-1];
        s = A.solve(g ^ x, g ^ y);
        return s;
      }

      proc main(): bool = {
        var z, s;

        s = aux();
        z = $Duni.duni s;
        return z = g ^ (x * y);
      }
    }.

    lemma Reduction &m:
      0 < n =>
      1%r / n%r * Pr[SCDH(A).main() @ &m: res]
      <= Pr[CDH.CDH(CDH_from_SCDH(A)).main() @ &m: res].
    proof.
      (* Move "0 < n" into the context *)
      move=> n_pos.
      (* We prove the inequality by transitivity:
           1%r/n%r * Pr[SCDH(A).main() @ &m: res]
           <= Pr[SCDH'.main() @ &m: res]
           <= Pr[CDH.CDH(CDH_from_SCDH(A)).main() @ &m: res]. *)
      (* "first last" allows us to first focus on the second inequality, which is easier. *)
      apply (real_le_trans _ Pr[SCDH'.main() @ &m: res]); first last.
        (* Pr[SCDH'.main() @ &m: res] <= Pr[CDH.CDH(CDH_from_SCDH(A)).main() @ &m: res] *)
        (* This is in fact an equality, which we prove by program equivalence *)
        byequiv (_: _ ==> ={res})=> //=.
        by proc; inline *; auto; call (_: true); auto.
      (* 1%r/n%r * Pr[SCDH(A).main() @ &m: res] <= Pr[SCDH'.main() @ &m: res] *)
      (* We do this one using a combination of phoare (to deal with the final sampling of z)
         and equiv (to show that SCDH'.aux and CDH.CDH are equivalent in context). *)
      byphoare (_: (glob A) = (glob A){m} ==> _)=> //.
      (* This line is due to a bug in proc *) pose d:= 1%r/n%r * Pr[SCDH(A).main() @ &m: res].
      pose p:= Pr[SCDH(A).main() @ &m: res]. (* notation for ease of writing below *)
      proc.
      (* We split the probability computation into:
           - the probability that s contains g^(x*y) and that |s| <= n is Pr[SCDH(A).main() @ &m: res], and
           - when s contains g^(x*y), the probability of sampling that one element uniformly in s is bounded
             by 1/n. *)
      seq  1: (mem (g ^ (SCDH'.x * SCDH'.y)) s /\ card s <= n) p (1%r/n%r) _ 0%r => //. 
        (* The first part is dealt with by equivalence with SCDH. *)
        conseq (_: _: =p). (* strengthening >= into = for simplicity*)
          call (_: (glob A) = (glob A){m}  ==> mem (g^(SCDH'.x * SCDH'.y)) res /\ card res <= n)=> //.
            bypr; progress; rewrite /p.
            byequiv (_: )=> //.
            by proc *; inline *; wp; call (_: true); auto.
      (* The second part is just arithmetic, but smt needs some help. *)
      rnd ((=) (g^(SCDH'.x * SCDH'.y))).
      skip; progress.
      rewrite Duni.mu_def; first smt.
      cut ->: card (filter ((=) (g^(SCDH'.x * SCDH'.y))) s){hr} = 1 by smt.
      cut H1: 0 < card s{hr} by smt.
      by rewrite -!inv_def inv_le; smt.
    qed.  
  end section.

(*
  (** Shoup's reduction to CDH -- the proof can be done using loop fusion *)
  module CDH_from_SCDH_Shoup (A:Adversary, B:Adversary) : CDH.Adversary = {
    proc solve(gx:group, gy:group) : group = {
      var a, b, s1, s2, r;

      s1 = A.solve(gx, gy);
      a = $[0..q-1];
      b = $[0..q-1];
      s2 = B.solve(gx ^ a * g ^ b, g ^ b);    
      r = pick (filter (fun (z:group), mem (z ^ a * gy ^ b) s2) s1);
      return r;
    }
  }.
*)
end Set_CDH.
