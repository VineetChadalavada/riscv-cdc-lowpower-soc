`default_nettype none

// minisoc -- the switchable power domain: the core, its power switch, and
// the isolation clamps on everything it drives out.
//
//           PD_CORE                               │  PD_AON
//   core_p5 ── outputs ── [power switch model] ── │─ iso_clamp ──► rest of chip
//      ▲                                          │      ▲
//      └── gclk, rst_n, inputs ◄──────────────────│      iso_en (from the PMU)
//
// Inputs into the core need no isolation: a powered-off block receiving a
// signal does no harm. Outputs do: a powered-off block drives nothing
// defined, and whatever reads those wires would see garbage.
//
// POWER-AWARE SIMULATION WITHOUT A POWER-AWARE SIMULATOR
// Real flows describe power in a UPF file (upf/minisoc.upf) and simulate
// with a tool that reads it (Synopsys VCS NLP, Siemens Questa PA). Vivado's
// simulator cannot. So the effects of switching off are modelled here, in
// simulation only (`ifndef SYNTHESIS):
//   - while pwr_on is low, every output of the domain is X;
//   - on power-down, the register file is filled with X, because it has no
//     reset and its contents are lost in silicon.
// Everything else in the core is reset on the way back up. If isolation is
// missing or late, the X gets out into the always-on logic and the
// testbench catches it.

module core_pd (
    input  wire        gclk,            // gated core clock
    input  wire        rst_n,           // core reset (from the PMU, and the chip reset)
    input  wire        pwr_on,
    input  wire        iso_en,

    output wire        imem_valid,
    output wire [31:0] imem_addr,
    input  wire        imem_ready,
    input  wire [31:0] imem_rdata,
    input  wire        imem_fault,

    output wire        dmem_valid,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    input  wire        dmem_ready,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_fault,

    input  wire        irq_timer,
    output wire        fsm_fault
);

    // everything the domain drives out, as one bus: 1+32+1+32+32+4+1 = 103 bits
    localparam W = 103;
    wire [W-1:0] out_core, out_domain;

    core_p5 #(.RESET_PC(32'h0)) u_core (
        .clk(gclk), .rst_n(rst_n),
        .imem_valid(out_core[102]), .imem_addr(out_core[101:70]),
        .imem_ready(imem_ready), .imem_rdata(imem_rdata), .imem_fault(imem_fault),
        .dmem_valid(out_core[69]), .dmem_addr(out_core[68:37]),
        .dmem_wdata(out_core[36:5]), .dmem_wstrb(out_core[4:1]),
        .dmem_ready(dmem_ready), .dmem_rdata(dmem_rdata), .dmem_fault(dmem_fault),
        .irq_timer(irq_timer), .irq_external(1'b0),
        .fsm_fault(out_core[0])
    );

`ifndef SYNTHESIS
    // ---- simulation model of the power switch ----
    assign out_domain = pwr_on ? out_core : {W{1'bx}};

    integer r;
    always @(negedge pwr_on)
        for (r = 1; r < 32; r = r + 1)
            u_core.u_regfile.regs[r] = 32'bx;
`else
    assign out_domain = out_core;
`endif

    // ---- isolation: clamp every output to 0 while iso_en is high ----
    // Written as its own cell so that the UPF can name it, and so that an
    // ASIC flow maps it onto the library's isolation cell.
    iso_clamp0 #(.W(W)) u_iso (.d(out_domain), .iso_en(iso_en), .q({
        imem_valid, imem_addr, dmem_valid, dmem_addr, dmem_wdata, dmem_wstrb, fsm_fault}));

endmodule


// Isolation cell, clamp to 0: q = d while iso_en is low, 0 while it is high.
// An AND gate with the enable inverted; X & 0 = 0, so an unpowered (X)
// input comes out as a clean 0.
module iso_clamp0 #(
    parameter W = 1
) (
    input  wire [W-1:0] d,
    input  wire         iso_en,
    output wire [W-1:0] q
);
    assign q = d & {W{~iso_en}};
endmodule

`default_nettype wire
