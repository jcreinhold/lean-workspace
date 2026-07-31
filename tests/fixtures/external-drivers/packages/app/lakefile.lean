import Lake
open Lake DSL

package «app» where
  lintDriver := "shared/runner"
  lintDriverArgs := #["App"]
  testDriver := "shared/verify"

require shared from "../../vendor/shared"

lean_lib App where
