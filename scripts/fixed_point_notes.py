#!/usr/bin/env python3
"""
fixed_point_notes.py - a runnable example of INT8 quantization.

EXPLANATION
    Neural networks are trained in float32, but inference hardware is much
    cheaper and faster in INT8. We use scale-factor quantization:

    real_value  ~=  scale * int8_value

    where 'scale' is a float chosen so the tensor's value range maps onto
    [-127, +127]. The hardware then multiplies INT8s, accumulates
    in INT32 (your ACC_WIDTH=32), and only converts back to real units at
    the very end with a single multiply by (scale_A * scale_B).

WHY ML ACCELERATORS USE INT8
    - An INT8 multiplier is substantially smaller and lower-energy than an FP32 one.
    - 4x less memory traffic than FP32.
    - An 8x8 signed multiply fits comfortably in one Cyclone 10 GX 18x19 DSP block, 
    whereas an FP32 multiply requires floating-point DSP modes.

This script demonstrates the full round trip on a tiny matrix multiply, and
prints the quantization error, which is small but nonzero.
"""

import random

random.seed(42)


def choose_scale(values, num_bits=8):
    """
    Symmetric quantization: map max|value| to the top of the int range.

    scale = max|x| / 127   so that   round(x / scale) is always in [-127, 127].
    """
    max_abs = max(abs(v) for v in values) or 1e-12
    qmax = 2 ** (num_bits - 1) - 1          # 127 for INT8
    return max_abs / qmax


def quantize(x, scale):
    """
    real to int8 (rounding, then clamping to the full INT8 range [-128, 127]).
    """
    q = round(x / scale)
    return max(-128, min(127, q))


def dequantize(q, scale):
    """
    int8 to approximate real value.
    """
    return q * scale


def main():
    n = 4
    # 1. Example float32 activations and weights from a trained net.
    A_real = [[random.uniform(-3.0, 3.0) for _ in range(n)] for _ in range(n)]
    B_real = [[random.uniform(-0.5, 0.5) for _ in range(n)] for _ in range(n)]

    # 2. Pick one scale per tensor (per-tensor symmetric quantization).
    sA = choose_scale([v for row in A_real for v in row])
    sB = choose_scale([v for row in B_real for v in row])
    print(f"scale_A = {sA:.6f}   (A values ~ scale_A * int8)")
    print(f"scale_B = {sB:.6f}   (B values ~ scale_B * int8)\n")

    # 3. Quantize to INT8 - These are the numbers the FPGA sees.
    A_q = [[quantize(v, sA) for v in row] for row in A_real]
    B_q = [[quantize(v, sB) for v in row] for row in B_real]
    print("A quantized to INT8 (first row):", A_q[0])
    print("B quantized to INT8 (first row):", B_q[0], "\n")

    # 4. INTEGER matrix multiply with INT32 accumulation - 
    #    what pe_mac.sv / the systolic array does. 
    C_int32 = [[sum(A_q[i][k] * B_q[k][j] for k in range(n)) for j in range(n)]
               for i in range(n)]

    # 5. One final dequantize step recovers approximate real results:
    #    C_real ~= (scale_A * scale_B) * C_int32
    #    One multiply per output, done once.
    C_approx = [[dequantize(v, sA * sB) for v in row] for row in C_int32]

    # 6. Compare against the exact float reference.
    C_exact = [[sum(A_real[i][k] * B_real[k][j] for k in range(n)) for j in range(n)]
               for i in range(n)]

    print("row 0 of C, exact float :", ["%8.4f" % v for v in C_exact[0]])
    print("row 0 of C, via INT8    :", ["%8.4f" % v for v in C_approx[0]])

    max_err = max(abs(C_approx[i][j] - C_exact[i][j]) for i in range(n) for j in range(n))
    max_mag = max(abs(C_exact[i][j]) for i in range(n) for j in range(n))
    print(f"\nmax abs error = {max_err:.5f}  ({100*max_err/max_mag:.2f}% of largest value)")
    print("\nThe FPGA only ever needs INT8 multipliers + an INT32")
    print("accumulator. The float scales live entirely in software.")


if __name__ == "__main__":
    main()
