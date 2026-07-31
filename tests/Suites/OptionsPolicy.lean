/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The options-policy suite

Port of `test/run.sh`'s `[options]` phase: a member that does not set a
required workspace option fails `check` with a diagnostic naming the member
and the option, and the compliant member in the same workspace must not be
flagged. ([options] is validation policy, never propagation — Lake
`leanOptions` do not propagate root → dependencies.)
-/

namespace Suites.OptionsPolicy

open Lakew.Test

end Suites.OptionsPolicy

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  let cases : Array Lakew.Test.Case := #[
    ⟨"a member missing a required option fails check; the compliant member passes", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / "options-policy"
        Lakew.Test.copyFixture "options-policy" dir
        let result ← Lakew.Test.expectExit "check" 1 lakew.toString #["check"] dir
        let out := result.stdout ++ result.stderr
        Lakew.Test.ensureContains "names member and option"
          "member `bad` does not set required workspace option `linter.missingDocs`" out
        Lakew.Test.ensureAbsent "compliant member not flagged" "member `good`" out⟩]
  Lakew.Test.runCases "options-policy" cases args
