def main (args : List String) : IO UInt32 := do
  IO.println s!"exe tests passed ({args})"
  return 0
