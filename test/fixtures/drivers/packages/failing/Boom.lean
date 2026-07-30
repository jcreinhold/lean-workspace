def main : IO UInt32 := do
  IO.eprintln "boom: deliberate failure"
  return 3
