import Lake
open Lake DSL

package «tactics» where

require «syntax» from "../syntax"

@[default_target]
lean_lib Tactic where
