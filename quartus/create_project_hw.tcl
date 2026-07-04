# =============================================================================
# create_project_hw.tcl - Quartus project for the physical board demo.
#   
#   Top entity = hw_top. 
#   Produces a real .sof to be programmed over JTAG.
#   Has only some real pins (clk + 2 buttons + 1 switch + 3 LEDs), so it needs real pin
#   assignments via hw_top_pins_template.tcl
#
# USAGE:
#   Quartus Tcl Console:  cd <...>/quartus ; source create_project_hw.tcl
#   then EDIT + source hw_top_pins_template.tcl, then Start Compilation.
# =============================================================================

package require ::quartus::project
catch {cd [file dirname [info script]]}

project_new int8_matmul_hw -overwrite

# Device
set_global_assignment -name FAMILY "Cyclone 10 GX"
set_global_assignment -name DEVICE 10CX220YF780E5G   ;

# Top level and sources
set_global_assignment -name TOP_LEVEL_ENTITY hw_top
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul_pkg.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/pe_mac.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/sequential_matmul.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/systolic_pe.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/systolic_array.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul_controller.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/matmul_top.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/hw_top.sv

# Timing constraints 
set_global_assignment -name SDC_FILE hw_top.sdc

# Output + effort 
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

# No virtual pins here, hw_top's ports are all real.
# Pin locations come from hw_top_pins_template.tcl 

export_assignments
project_close
puts "Project int8_matmul_hw created (top = hw_top)."
puts "NEXT: edit hw_top_pins_template.tcl with your board pins, source it, then compile."
