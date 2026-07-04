#!/usr/bin/env python3
"""
verify_results.py - compare a simulation output dump against C_expected.hex.

The testbenches already self-check and print PASS/FAIL, so this script is a
second check. tb_matmul_top.sv writes the hardware result of the hex-vector test
to vectors/C_hw_out.hex (one 8-hex-digit 32-bit word per line, row-major).

USAGE (from the project root, after running the simulation):
    python3 scripts/verify_results.py
    python3 scripts/verify_results.py --hw vectors/C_hw_out.hex --gold vectors/C_expected.hex
"""

import argparse
from pathlib import Path
 
 
def read_hex_words(path, bits):
    """Read a $readmemh-style hex file into a list of signed Python ints."""
    vals = []
    for line in Path(path).read_text().splitlines():
        line = line.split("//")[0].strip()   # strip comments and whitespace
        if not line:
            continue                          # skip blank and comment-only lines
        raw = int(line, 16)                   # parse the hex word as unsigned
        # Convert two's complement bit pattern back to a signed integer.
        # A value with the top bit set represents a negative number, so subtract
        # 2^bits to recover its signed value.
        if raw >= (1 << (bits - 1)):
            raw -= (1 << bits)
        vals.append(raw)
    return vals
 
 
def main():
    # Both file paths are optional. They default to the standard vectors dir and
    # can be overridden.
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw",   default=None, help="hardware output dump")
    ap.add_argument("--gold", default=None, help="golden expected values")
    args = ap.parse_args()
 
    # Anchor defaults to <project_root>/vectors so this runs from anywhere
    # (terminal, IDLE, double-click).
    PROJECT_ROOT = Path(__file__).resolve().parent.parent
    if args.hw is None:
        args.hw = str(PROJECT_ROOT / "vectors" / "C_hw_out.hex")
    if args.gold is None:
        args.gold = str(PROJECT_ROOT / "vectors" / "C_expected.hex")
 
    # The hardware dump is produced by the simulation, so a missing file 
    # means the testbench has not been run yet. 
    if not Path(args.hw).exists():
        raise SystemExit(f"{args.hw} not found - run the tb_matmul_top simulation first "
                         "(it writes this file).")
 
    # Both results are 32-bit signed to match the accumulator width.
    hw   = read_hex_words(args.hw, 32)
    gold = read_hex_words(args.gold, 32)
 
    # A length mismatch means the two files describe different-sized matrices,
    # which would make an element-wise compare meaningless.
    if len(hw) != len(gold):
        raise SystemExit(f"Length mismatch: hw has {len(hw)} values, golden has {len(gold)}")
 
    # Results are stored row-major and flat, so N is the square root of the count.
    n = int(len(gold) ** 0.5)
    errors = 0
    for idx, (h, g) in enumerate(zip(hw, gold)):
        # Recover the 2-D coordinate from the flat index.
        i, j = idx // n, idx % n
        status = "ok" if h == g else "MISMATCH"
        # Only the failing cells are printed.
        if h != g:
            errors += 1
            print(f"  C[{i}][{j}]: hw = {h:>8d}, expected = {g:>8d}   <-- {status}")
 
    # Summarize and set exit status. 
    if errors == 0:
        print(f"PASS: all {len(gold)} elements of C match the golden model.")
    else:
        print(f"FAIL: {errors}/{len(gold)} elements differ.")
        raise SystemExit(1)
 
 
if __name__ == "__main__":
    main()