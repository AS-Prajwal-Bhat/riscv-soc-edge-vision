# RISC-V SoC for Edge Image Classification

A Verilog-based system-on-chip integrating a five-stage RISC-V processor with dedicated hardware accelerators for image preprocessing and classification.

The system accepts a 32 × 32 grayscale image over UART, stores image data in shared memory, performs block-based Discrete Cosine Transform (DCT), and executes a quantized CNN inference pipeline. The predicted class is returned over UART and displayed through the seven-segment interface.

## System Overview

| Component | Implementation |
|---|---|
| Processor | 32-bit, five-stage RISC-V pipeline |
| Pipeline | Instruction Fetch, Decode, Execute, Memory, Writeback |
| Hazard handling | Operand forwarding, stalls and pipeline flushes |
| Image input | UART, 115200 baud |
| Preprocessing | Hardware 8 × 8 DCT |
| Classification | Fixed-point, quantized LeNet-5-inspired CNN |
| Memory | Shared BRAM with CPU and accelerator arbitration |
| Control | Memory-mapped I/O and frame controller |
| Output | UART classification result and seven-segment display |
| HDL | Verilog |
| FPGA constraints | Real Digital Blackboard Rev D constraint file included |

## Architecture

The SoC combines a general-purpose processor with hardware blocks dedicated to the image-processing workload.

### Processor

The processor implements a five-stage pipeline:

`IF → ID → EX → MEM → WB`

The RTL includes:

- Instruction decoding and register-file access.
- Arithmetic and logic operations.
- Branch and jump handling.
- Operand forwarding between pipeline stages.
- Load-use hazard handling.
- Pipeline stalls and flushes.
- Memory-mapped peripheral access.

### DCT Accelerator

The DCT engine processes an image as a grid of sixteen 8 × 8 blocks.

The frame controller configures the input and output addresses and strides for each block, starts the DCT operation and monitors its completion before advancing to the next block.

### CNN Accelerator

The CNN accelerator implements a fixed-point inference datapath with quantized weights.

The RTL contains the following network structure:

| Layer | Output dimensions |
|---|---:|
| Input | 32 × 32 |
| Convolution 1 | 28 × 28 × 6 |
| Pooling 1 | 14 × 14 × 6 |
| Convolution 2 | 10 × 10 × 16 |
| Pooling 2 | 5 × 5 × 16 |
| Fully connected 1 | 120 |
| Fully connected 2 | 84 |
| Fully connected 3 | 10 classes |

The accelerator reads its parameters from a dedicated weight ROM and uses shared memory for intermediate activation data.

### SoC Integration

The top-level design integrates:

- RISC-V processor
- MMIO controller
- UART peripheral
- DCT accelerator
- CNN accelerator
- Frame controller
- Shared BRAM and accelerator arbiter
- CNN weight ROM
- GPIO debug outputs
- Seven-segment display controller

The frame controller sequences the complete block-processing operation and subsequently invokes CNN inference.

## Image Processing Flow

1. A host sends 1,024 grayscale pixel bytes through UART.
2. The processor and memory-mapped peripherals handle incoming data and memory transfers.
3. The frame controller schedules the sixteen 8 × 8 DCT operations.
4. The DCT coefficients are stored in shared memory.
5. The CNN accelerator processes the transformed frame.
6. The predicted class is made available to the system.
7. The classification result is transmitted through UART and presented on the seven-segment display.

## Repository Structure

```text
riscv-soc-edge-vision/
├── rtl/
│   ├── riscv_core.v
│   ├── riscv_core_pkg.v
│   ├── riscv_soc.v
│   ├── accelerators.v
│   ├── peripherals.v
│   └── seg7_display.v
├── tb/
│   └── tb_riscv_soc.v
├── mem/
│   ├── firmware.hex
│   ├── lenet5_weights.hex
│   └── digit5_32x32.hex
├── constraints/
│   └── riscv_soc.xdc
├── docs/
│   └── digit5_preview.png
└── .gitignore
```

## Simulation

The repository contains a system-level testbench intended to exercise the image-transfer and inference flow.

### Requirements

- Xilinx Vivado Simulator (XSim), or a compatible Verilog simulator.
- The RTL source files.
- The firmware, CNN weight and sample image memory files.

### Vivado setup

1. Create a Vivado project.
2. Add all Verilog files under `rtl/` as design sources.
3. Set `riscv_soc` as the synthesis top.
4. Add `tb/tb_riscv_soc.v` as a simulation source.
5. Set `tb_riscv_soc` as the simulation top.
6. Make the three files in `mem/` available in the simulator's working directory, because the current `$readmemh` calls use filenames rather than repository-relative paths.
7. Run behavioral simulation.

The testbench uses `digit5_32x32.hex` as its sample input. Note that the testbench also contains a reference to `dog_32x32.hex`; that additional image is not included in the current repository.

## Verification Evidence

The testbench implements a UART-to-classification simulation sequence:

- Reset and processor startup.
- Transmission of a 1,024-byte image.
- DCT and CNN execution.
- Reception of a classification byte over UART.
- A timeout watchdog and diagnostic signal monitors.

A recorded project simulation is reported to have returned class `5` for the supplied digit-five image.

This is a sample-based functional demonstration, not a statistical evaluation of classification accuracy. No dataset-wide accuracy, throughput, power or FPGA timing figures are claimed here.

## FPGA Implementation

The repository includes an XDC file identifying the target as the Real Digital Blackboard Rev D, using device `xc7z007sclg400-1`.

The RTL selects a 75 MHz system clock in synthesis and a 100 MHz pass-through clock in simulation. The clocking and timing constraints should be checked against the final Vivado implementation before treating the design as timing-closed.

Synthesis utilization, achieved clock frequency and implementation results are not included because a verified final implementation report is not currently part of this repository.

## Current Limitations

- The published repository does not yet include a complete Vivado project with project configuration and generated implementation reports.
- Simulation memory-file paths require working-directory configuration.
- The optional second test image referenced by the testbench is not included.
- Classification performance has not been established through a dataset-wide evaluation.
- FPGA resource utilization and timing closure remain to be documented from a reproducible implementation run.

## Future Work

- Make simulation setup reproducible with explicit memory-file paths.
- Add automated regression tests for processor, peripheral and accelerator behavior.
- Validate classifications against a software reference implementation.
- Evaluate accuracy over a representative image dataset.
- Add synthesis and implementation reports.
- Measure inference latency, operating frequency and resource utilization.

## Author

**A S Prajwal Bhat**

[GitHub](https://github.com/AS-Prajwal-Bhat) · [Portfolio](https://as-prajwal-bhat.github.io/AS_Prajwal_Bhat/)