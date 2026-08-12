package require ::quartus::project
package require ::quartus::flow

set base_dir [pwd]

project_open -revision ap_core src/fpga/build/gba_pocket.qpf
set_global_assignment -name NUM_PARALLEL_PROCESSORS 16
execute_flow -compile
project_close

# project_open changes cwd to the project directory; restore it
cd $base_dir

# Run custom STA report for detailed timing path analysis.
# Dev builds can skip it: set env HAN_DEV_BUILD=1 to only produce the
# bitstream (compile gets faster; timing is still checked by the normal
# execute_flow timing analysis).
if {[info exists env(HAN_DEV_BUILD)] && $env(HAN_DEV_BUILD) == "1"} {
    post_message "HAN dev build: skipping custom STA report"
} else {
    file mkdir build_output/reports
    post_message "Running custom STA report..."
    if {[catch {qexec "quartus_sta -t scripts/sta_custom_report.tcl"} result]} {
        post_message -type warning "Custom STA report failed: $result"
    } else {
        post_message "Custom STA completed successfully."
    }

    # Verify reports were generated
    foreach f {build_output/reports/ap_core.sta.paths_setup.rpt
               build_output/reports/ap_core.sta.paths_hold.rpt
               build_output/reports/ap_core.sta.clock_summary.rpt} {
        if {[file exists $f]} {
            post_message "Report OK: $f"
        } else {
            post_message -type warning "Report MISSING: $f"
        }
    }
}
