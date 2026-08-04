import Lake
open Lake DSL

package aux

-- No `@[default_target]`: `lake build @aux` is a Lake no-op, and lakew
-- should say so in the plan notes.
lean_lib Aux
