import Lake
open Lake DSL

package «tactics» where

require core from "../core"
require «syntax» from "../syntax"

@[default_target]
lean_lib Tactic where
