import Lake
open Lake DSL

package «good» where
  moreLeanOptions := #[
    ⟨`linter.missingDocs, true⟩,
    ⟨`maxSynthPendingDepth, .ofNat 3⟩ ]

lean_lib Good where
