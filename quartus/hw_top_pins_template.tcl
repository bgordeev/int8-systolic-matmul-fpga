# =============================================================================
# hw_top_pins_template.tcl - Pin assignment template for the board demo.
#
# THIS FILE INTENTIONALLY CONTAINS NO REAL PIN LOCATIONS.
#
# You must fill in the PIN_xxx locations and I/O standards from your board's
# documentation.
#
# WHERE TO GET THE REAL VALUES:
#      The kit's "Golden Top" reference Quartus project:
#      open its .qsf in a text editor and copy the exact
#      set_location_assignment / IO_STANDARD lines for the parts you use,
#      renaming the port to the hw_top names below. 
#
# HOW TO APPLY:
#   - Quartus Tcl Console:  cd <...>/quartus ; source hw_top_pins_template.tcl
#   - Or open Assignments > Pin Planner and type Location + I/O Standard for
#     each port by hand (same values).
#
# =============================================================================

# -----------------------------------------------------------------------------
# 1) Clock input.
# -----------------------------------------------------------------------------
# set_location_assignment PIN_<FILL_IN> -to clk
# set_instance_assignment -name IO_STANDARD "<FILL_IN e.g. 1.8 V>" -to clk

# -----------------------------------------------------------------------------
# 2) Pushbuttons and switch.
# -----------------------------------------------------------------------------
# set_location_assignment PIN_<FILL_IN> -to rst_n
# set_instance_assignment -name IO_STANDARD "<FILL_IN>" -to rst_n
#
# set_location_assignment PIN_<FILL_IN> -to btn_start
# set_instance_assignment -name IO_STANDARD "<FILL_IN>" -to btn_start
#
# set_location_assignment PIN_<FILL_IN> -to sw_sel
# set_instance_assignment -name IO_STANDARD "<FILL_IN>" -to sw_sel

# -----------------------------------------------------------------------------
# 3) LEDs.
# -----------------------------------------------------------------------------
# set_location_assignment PIN_<FILL_IN> -to led_pass
# set_instance_assignment -name IO_STANDARD "<FILL_IN>" -to led_pass
#
# set_location_assignment PIN_<FILL_IN> -to led_done
# set_instance_assignment -name IO_STANDARD "<FILL_IN>" -to led_done
#
# set_location_assignment PIN_<FILL_IN> -to led_heartbeat
# set_instance_assignment -name IO_STANDARD "<FILL_IN>" -to led_heartbeat

# -----------------------------------------------------------------------------
# 4) Safe default for the ~700 pins not used
# -----------------------------------------------------------------------------
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED WITH WEAK PULL-UP"

# export_assignments
puts "Edit the FILL_IN pin locations/standards."
