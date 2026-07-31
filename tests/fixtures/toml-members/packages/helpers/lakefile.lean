import Lake
open Lake DSL

package «helpers» where
  leanOptions := #[⟨`linter.missingDocs, true⟩]

lean_lib Helpers where
