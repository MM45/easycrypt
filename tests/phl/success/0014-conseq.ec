module M = { 
  fun f() : unit = {}
}.

lemma foo : hoare [M.f : false ==> true].
proof.
  conseq ( _: true ==> false).
  smt.
  smt.
  admit.
save.