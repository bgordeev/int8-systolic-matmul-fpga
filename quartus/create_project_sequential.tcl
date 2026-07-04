# =============================================================================
# create_project_sequential.tcl
#   Builds a SEPARATE Quartus Prime Pro project with
#   (sequential_matmul) as the top-level entity, for per-engine
#   area/Fmax characterization.
# -----------------------------------------------------------------------------
# USAGE options:
# (a) Quartus Tcl Console:  cd <...>/quartus ; source create_project_sequential.tcl
# (b) Quartus cmd prompt:   cd <...>/quartus ; quartus_sh -t create_project_sequential.tcl
# (c) Tools > Tcl Scripts in the GUI (this script anchors its own path).
# Then: File > Open Project > int8_matmul_sequential.qpf, and compile.
#
# sequential_matmul ports: clk, rst_n, start, a_in, b_in, c_flat, busy, done. 
# clk stays a REAL pin.
# Every data/control port is virtual.
# =============================================================================

package require ::quartus::project

catch {cd [file dirname [info script]]}

project_new int8_matmul_sequential -overwrite

# Device 
set_global_assignment -name FAMILY "Cyclone 10 GX"
set_global_assignment -name DEVICE 10CX220YF780E5G   ;

# Top level and sources 
# sequential_matmul pulls in pe_mac and the package.
# Extra files (sequential/pe_mac/top) are harmless.
set_global_assignment -name TOP_LEVEL_ENTITY sequential_matmul
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul_pkg.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/pe_mac.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/sequential_matmul.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/systolic_pe.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/systolic_array.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul_controller.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul_top.sv

# Timing constraints 
set_global_assignment -name SDC_FILE constraints.sdc

# Virtual pins for all data/control I/O (clk stays physical)
set_instance_assignment -name VIRTUAL_PIN ON -to a_in*
set_instance_assignment -name VIRTUAL_PIN ON -to b_in*
set_instance_assignment -name VIRTUAL_PIN ON -to c_flat*
set_instance_assignment -name VIRTUAL_PIN ON -to start
set_instance_assignment -name VIRTUAL_PIN ON -to rst_n
set_instance_assignment -name VIRTUAL_PIN ON -to busy
set_instance_assignment -name VIRTUAL_PIN ON -to done

# Defaults 
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

export_assignments
project_close
puts "Project int8_matmul_sequential created (top = sequential_matmul)."
puts "Open int8_matmul_sequential.qpf and run Start Compilation."
