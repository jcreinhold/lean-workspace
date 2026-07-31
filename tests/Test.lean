/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test.Harness
public import Test.Proc
public import Test.Fixture
public import Test.Golden

/-!
# The shared test library

`import Test` gives a suite the whole harness. The pieces stay separate
modules so the import graph records what each suite uses; this root lets the
lakefile glob one namespace and suites write one import line.
-/
