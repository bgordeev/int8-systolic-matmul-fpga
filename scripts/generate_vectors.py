#!/usr/bin/env python3
"""
generate_vectors.py - the "golden model" for the FPGA accelerator.

WHAT THIS DOES
    1. Generates random signed INT8 matrices A and B (with a configurable
       magnitude limit so one can reason about overflow).
    2. Computes C = A x B in plain Python (the ground truth).
    3. Writes A, B, C to hex files that the SystemVerilog testbenches load
       with $readmemh.
    4. Prints all three matrices in human-readable form.

HEX FILE FORMAT (must match the testbenches)
    - A_matrix.hex / B_matrix.hex : one element per line, 2 hex digits,
      TWO'S COMPLEMENT (so -1 is "ff", -128 is "80"). Row-major order:
      A[0][0], A[0][1], ..., A[0][N-1], A[1][0], ...
    - C_expected.hex : one element per line, 8 hex digits (32-bit two's
      complement), same row-major order.

WHY TWO'S COMPLEMENT MATTERS
    $readmemh just loads raw bits. The hardware interprets those bits as
    signed because the ports are declared 'signed'. If this script wrote
    sign-magnitude or decimal, everything would mismatch.

USAGE (run from the project root)
    python3 scripts/generate_vectors.py                  # defaults: N=4, |x|<=16, seed=2026
    python3 scripts/generate_vectors.py --size 4 --max-mag 127 --seed 7
"""

import argparse
import random
from pathlib import Path
 

# Two's-complement helpers
def to_hex_twos_complement(value: int, bits: int) -> str:
    """
    Encode a Python int (possibly negative) as a fixed-width hex string.
 
    Example: to_hex_twos_complement(-1, 8)  -> 'ff'
             to_hex_twos_complement(5, 32)  -> '00000005'
    """
    # Masking with (2^bits - 1) reduces a negative value to its two's-complement
    # bit pattern in the target width.
    mask = (1 << bits) - 1
    # bits // 4 hex digits give exactly 'bits' bits, zero padded.
    return format(value & mask, f"0{bits // 4}x")
 
 
def matmul(A, B):
    """
    Plain Python matrix multiply (the golden reference).
    """
    n = len(A)
    return [[sum(A[i][k] * B[k][j] for k in range(n)) for j in range(n)]
            for i in range(n)]
 
 
def print_matrix(name, M):
    # One matrix with aligned signed columns for the console summary.
    print(f"\n{name} =")
    for row in M:
        print("   [" + " ".join(f"{v:6d}" for v in row) + " ]")
 
 
def main():
    # Command-line interface. Every generation parameter is exposed so different
    # test cases can be produced without editing the script.
    ap = argparse.ArgumentParser(description="Generate INT8 matmul test vectors")
    ap.add_argument("--size", type=int, default=4, help="matrix dimension N (default 4)")
    ap.add_argument("--max-mag", type=int, default=16,
                    help="max |element| value, <=127 (default 16)")
    ap.add_argument("--seed", type=int, default=2026, help="RNG seed for reproducibility")
    ap.add_argument("--outdir", type=str, default=None,
                    help="output directory (default: <project_root>/vectors)")
    args = ap.parse_args()
 
    # Anchor the default output to the project root, so the vectors land in the right
    # place no matter where they are launched from: terminal, IDLE, or double click.
    PROJECT_ROOT = Path(__file__).resolve().parent.parent
    if args.outdir is None:
        args.outdir = str(PROJECT_ROOT / "vectors")
 
    # Reject magnitudes outside signed INT8 range before generating anything.
    if not (1 <= args.max_mag <= 127):
        raise SystemExit("--max-mag must be between 1 and 127 (INT8 range)")
 
    # Seeded RNG so a given seed always reproduces the same matrices.
    rng = random.Random(args.seed)
    N = args.size
 
    # 1. random signed INT8 matrices 
    # Each element is drawn from [-max_mag, max_mag], keeping both operands in
    # signed INT8 range and exercising negative values.
    A = [[rng.randint(-args.max_mag, args.max_mag) for _ in range(N)] for _ in range(N)]
    B = [[rng.randint(-args.max_mag, args.max_mag) for _ in range(N)] for _ in range(N)]
 
    # 2. golden result 
    C = matmul(A, B)
 
    # Overflow sanity check: every C element must fit in the 32-bit accumulator.
    # Worst case: |A|·|B| ≤ 128·128 per term, so |C[i][j]| ≤ N·16384, which fits in 32 bits for any N
    # below roughly 131,000 - far beyond any size this design targets.
    for row in C:
        for v in row:
            assert -(2**31) <= v < 2**31, "C element overflows INT32 accumulator"
 
    # 3. write hex files 
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)   # create the target dir if absent
 
    def write_hex(path, matrix, bits):
        # Emit one matrix as a hex file. A comment header records the shape and
        # encoding, then values follow row-major, one per line, in the given width.
        with open(path, "w") as f:
            f.write(f"// {path.name}: {N}x{N}, row-major, {bits}-bit two's complement\n")
            for row in matrix:
                for v in row:
                    f.write(to_hex_twos_complement(v, bits) + "\n")
 
    # A and B are the 8-bit operands. C is 32-bit to match the accumulator width.
    write_hex(outdir / "A_matrix.hex", A, 8)
    write_hex(outdir / "B_matrix.hex", B, 8)
    write_hex(outdir / "C_expected.hex", C, 32)
 
    # 4. show the human-readable versions 
    print(f"Generated {N}x{N} test vectors (seed={args.seed}, |x| <= {args.max_mag})")
    print_matrix("A", A)
    print_matrix("B", B)
    print_matrix("C = A x B (expected)", C)
    print(f"\nWrote: {outdir}/A_matrix.hex, B_matrix.hex, C_expected.hex")
    print("Run the simulation next.")
 
 
if __name__ == "__main__":
    main()
