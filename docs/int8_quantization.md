# INT8 Quantization: Why ML Accelerators Use 8-bit Integers

## The core idea

Neural networks are trained in 32-bit floating point (FP32), but the values
in a tensor can be approximated as

    real_value  ~=  scale * int8_value

with a single floating-point scale per tensor. This is symmetric, per-tensor
quantization. Production frameworks extend it with per-channel scales and
zero-points. The scale is chosen as scale = max|x| / 127, and each value is
divided by the scale, rounded, and clamped to the range [-128, 127].

The useful property is what happens inside a dot product. Writing the
quantized operands as sA * a_i and sB * b_i:

    Sum (sA * a_i)(sB * b_i)  =  sA * sB * Sum (a_i * b_i)

The summation Sum (a_i * b_i) is pure integer arithmetic. The floating-point
scales factor out of the sum and are applied once per output element in
software, so the FPGA datapath operates entirely on integers.

## Why INT8 is used in hardware

| Aspect           | INT8 compared with FP32                                                                     |
|------------------|---------------------------------------------------------------------------------------------|
| Multiplier area  | Substantially smaller and lower energy.                                                     |
| Memory traffic   | Four times fewer bytes per value.                                                           |
| FPGA DSP fit     | An 8x8 signed multiply fits comfortably in a Cyclone 10 GX 18x19 variable-precision DSP block. FP32 requires floating-point DSP modes and more resources. |
| Accuracy cost    | Small for CNNs and transformers when the network is calibrated for low precision.                                                                   |

## Accumulator width (ACC_WIDTH = 32 in this project)

One INT8 x INT8 product needs 16 bits, since the worst case is
(-128)*(-128) = 16384. Summing K products needs 16 + ceil(log2(K)) bits.
K = 4 needs 18 bits, K = 1024 needs 26 bits, and K = 65536 needs 32 bits.
This project uses 32-bit (INT32) accumulation, which is safe for any realistic
layer size and matches common 32-bit bus and CPU widths. The general
principle is to quantize at the edges of the datapath and
accumulate at a wide precision inside it.

## Scope of this project

This accelerator implements the integer core: INT8 multiply with INT32
accumulation. It does not implement requantization (the INT32 back to INT8
conversion between layers, with rounding and saturation). Adding
requantization is the logical next step toward running a complete quantized
neural-network layer end to end.
