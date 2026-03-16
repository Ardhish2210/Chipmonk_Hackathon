# =============================================================================
# create_vivado_project.tcl
# Run from Vivado Tcl console:
#   source create_vivado_project.tcl
# Creates a Basys-3 project with all CNN accelerator sources added.
# =============================================================================

set proj_name  "cnn_accelerator_basys3"
set proj_dir   "./vivado_project"
set part_name  "xc7a35tcpg236-1"

# ── Create project ────────────────────────────────────────────────────────────
create_project $proj_name $proj_dir -part $part_name -force

set_property board_part digilentinc.com:basys3:part0:1.1 [current_project]

# ── Add RTL sources ───────────────────────────────────────────────────────────
# Core CNN modules (existing – unchanged)
add_files -norecurse {
    line_buffer.v
    window_generator.v
    weight_buffer.v
    mac_array.v
    accumulator.v
    activation_relu.v
    controller_fsm.v
}

# New FPGA integration modules
add_files -norecurse {
    image_rom.v
    feature_map_store.v
    cnn_accelerator_top.v
}

# ── Add memory initialisation file ───────────────────────────────────────────
# image.mem must sit next to the project or in the sim/synth search path.
add_files -norecurse { image.mem }
set_property file_type {Memory Initialization Files} [get_files image.mem]

# ── Add constraints ───────────────────────────────────────────────────────────
add_files -fileset constrs_1 -norecurse { basys3_cnn.xdc }

# ── Set top module ────────────────────────────────────────────────────────────
set_property top cnn_accelerator_top [current_fileset]
update_compile_order -fileset sources_1

# ── Optional: set default simulation top ─────────────────────────────────────
# add_files -fileset sim_1 -norecurse { tb_cnn_accelerator.v }
# set_property top tb_cnn_accelerator [get_filesets sim_1]

puts "Project '$proj_name' created for $part_name."
puts "Run: launch_runs impl_1 -to_step write_bitstream"
