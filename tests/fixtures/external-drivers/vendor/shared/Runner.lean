def main (args : List String) : IO UInt32 := do
  IO.println s!"external runner ran with {args}"
  return 0
