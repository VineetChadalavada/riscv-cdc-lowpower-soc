`default_nettype none

// minisoc -- top level.
//
//              clk_core                               │     clk_periph
//                                                     │
//   core_p5 ──imem──► tcm (RAM)                       │
//          └─dmem─┬─► tcm                 0x0000_0000 │
//                 ├─► perf_counters       0x2000_0000 │
//                 └─► cdc_apb_bridge ─────0x1000_0000─┼──► APB ─┬─► apb_uart_tx  0x1000_0000
//                                                     │         └─► apb_timer    0x1000_1000
//   irq_timer ◄──────────── sync_2ff ◄────────────────┼──────────── timer irq (level)
//
// Two clocks with no relationship, and each has its own reset synchronizer.
// Exactly three things cross between them, and each uses a verified CDC
// block:
//   core -> periph   bus requests      async_fifo (inside the bridge)
//   periph -> core   bus responses     async_fifo (inside the bridge)
//   periph -> core   timer interrupt   sync_2ff (a level, so safe)
//
// The CPU is TinyTrust's 5-stage RV32I core, used as-is.
//
// Two power domains (upf/minisoc.upf):
//   PD_CORE  the core alone, inside core_pd. Switchable: the PMU (0x3000_0000)
//            can isolate it, stop its clock, reset it and cut its power.
//   PD_AON   everything else, always on: RAM (so the program survives a
//            power-down), bridge, peripherals, counters and the PMU itself.
// The core does not keep its state across a power-down; it reboots, and
// reads the PMU's STATUS register to tell a wake-up from a cold start.

module minisoc_top #(
    parameter RAM_WORDS = 4096
) (
    input  wire clk_core,
    input  wire clk_periph,
    input  wire arst_n,          // asynchronous reset from a pin
    output wire uart_tx
);

    // ---------------------------------------------------------------
    // Resets, one per clock domain
    // ---------------------------------------------------------------
    wire rst_core_n, rst_periph_n;
    rst_sync u_rst_core   (.clk(clk_core),   .arst_n(arst_n), .rst_n(rst_core_n));
    rst_sync u_rst_periph (.clk(clk_periph), .arst_n(arst_n), .rst_n(rst_periph_n));

    // ---------------------------------------------------------------
    // Core, in its own power domain
    // ---------------------------------------------------------------
    wire        imem_valid, imem_ready, imem_fault;
    wire [31:0] imem_addr, imem_rdata;
    wire        dmem_valid, dmem_ready, dmem_fault;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        irq_timer_core;
    wire        fsm_fault;

    wire pd_pwr_on, pd_iso_en, pd_clk_en, pd_rst_n;
    wire gclk_core;

    icg u_icg (.clk(clk_core), .en(pd_clk_en), .gclk(gclk_core));

    // Both inputs are flop outputs in clk_core: the chip reset from its
    // synchronizer, and the PMU's reset request.
    wire core_rst_n = rst_core_n && pd_rst_n;

    core_pd u_core_pd (
        .gclk(gclk_core), .rst_n(core_rst_n), .pwr_on(pd_pwr_on), .iso_en(pd_iso_en),
        .imem_valid(imem_valid), .imem_addr(imem_addr),
        .imem_ready(imem_ready), .imem_rdata(imem_rdata), .imem_fault(imem_fault),
        .dmem_valid(dmem_valid), .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_ready(dmem_ready), .dmem_rdata(dmem_rdata), .dmem_fault(dmem_fault),
        .irq_timer(irq_timer_core),
        .fsm_fault(fsm_fault)
    );

    // ---------------------------------------------------------------
    // Address decode (clk_core)
    // ---------------------------------------------------------------
    localparam [31:0] RAM_BYTES = RAM_WORDS * 4;

    // instruction side: RAM only
    wire i_in_ram = (imem_addr < RAM_BYTES);
    wire ram_i_ready;
    assign imem_ready = i_in_ram ? ram_i_ready : imem_valid;   // outside RAM: fault at once
    assign imem_fault = !i_in_ram;

    // data side
    wire d_ram    = (dmem_addr[31:28] == 4'h0) && (dmem_addr < RAM_BYTES);
    wire d_periph = (dmem_addr[31:28] == 4'h1);
    wire d_perf   = (dmem_addr[31:28] == 4'h2);
    wire d_pmu    = (dmem_addr[31:28] == 4'h3);
    wire d_none   = !(d_ram || d_periph || d_perf || d_pmu);

    wire        ram_d_ready, br_ready, br_fault, br_busy, perf_ready, pmu_ready;
    wire [31:0] ram_d_rdata, br_rdata, perf_rdata, pmu_rdata;

    assign dmem_ready = d_ram    ? ram_d_ready
                      : d_periph ? br_ready
                      : d_perf   ? perf_ready
                      : d_pmu    ? pmu_ready
                      :            dmem_valid;                // no slave: fault at once
    assign dmem_rdata = d_ram    ? ram_d_rdata
                      : d_periph ? br_rdata
                      : d_perf   ? perf_rdata
                      :            pmu_rdata;
    assign dmem_fault = (d_periph && br_fault) || d_none;

    // ---------------------------------------------------------------
    // RAM (clk_core)
    // ---------------------------------------------------------------
    tcm #(.WORDS(RAM_WORDS)) u_tcm (
        .clk(clk_core), .rst_n(rst_core_n),
        .i_valid(imem_valid && i_in_ram), .i_addr(imem_addr),
        .i_ready(ram_i_ready), .i_rdata(imem_rdata),
        .d_valid(dmem_valid && d_ram), .d_addr(dmem_addr),
        .d_wdata(dmem_wdata), .d_wstrb(dmem_wstrb),
        .d_ready(ram_d_ready), .d_rdata(ram_d_rdata)
    );

    // ---------------------------------------------------------------
    // Performance counters (clk_core)
    // ---------------------------------------------------------------
    perf_counters u_perf (
        .clk(clk_core), .rst_n(rst_core_n),
        .valid(dmem_valid && d_perf), .addr(dmem_addr[7:0]), .write(dmem_wstrb != 4'd0),
        .ready(perf_ready), .rdata(perf_rdata),
        .ev_fetch(imem_valid && imem_ready), .ev_sleep(!pd_clk_en),
        .p_valid(dmem_valid && d_periph), .p_ready(br_ready)
    );

    // ---------------------------------------------------------------
    // Power management (always on, ungated clk_core)
    // ---------------------------------------------------------------
    pmu u_pmu (
        .clk(clk_core), .rst_n(rst_core_n),
        .valid(dmem_valid && d_pmu), .addr(dmem_addr[3:0]), .write(dmem_wstrb != 4'd0),
        .wdata(dmem_wdata), .ready(pmu_ready), .rdata(pmu_rdata),
        .bridge_busy(br_busy), .wake(irq_timer_core),
        .pwr_on(pd_pwr_on), .iso_en(pd_iso_en), .clk_en(pd_clk_en), .core_rst_n(pd_rst_n)
    );

    // ---------------------------------------------------------------
    // Bridge to the peripheral clock domain
    // ---------------------------------------------------------------
    wire [15:0] paddr;
    wire        psel, penable, pwrite, pready, pslverr;
    wire [31:0] pwdata, prdata;
    wire [3:0]  pstrb;

    cdc_apb_bridge u_bridge (
        .clk_core(clk_core), .rst_core_n(rst_core_n),
        .c_valid(dmem_valid && d_periph), .c_addr(dmem_addr),
        .c_wdata(dmem_wdata), .c_wstrb(dmem_wstrb),
        .c_ready(br_ready), .c_rdata(br_rdata), .c_fault(br_fault), .c_busy(br_busy),
        .clk_periph(clk_periph), .rst_periph_n(rst_periph_n),
        .paddr(paddr), .psel(psel), .penable(penable), .pwrite(pwrite),
        .pwdata(pwdata), .pstrb(pstrb),
        .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    // ---------------------------------------------------------------
    // Peripherals (clk_periph)
    // ---------------------------------------------------------------
    wire        psel_uart, psel_timer;
    wire [31:0] prdata_uart, prdata_timer;
    wire        pready_uart, pready_timer, pslverr_uart, pslverr_timer;
    wire        irq_timer_periph;

    apb_decoder u_dec (
        .psel(psel), .paddr(paddr),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .psel_uart(psel_uart),   .prdata_uart(prdata_uart),
        .pready_uart(pready_uart), .pslverr_uart(pslverr_uart),
        .psel_timer(psel_timer), .prdata_timer(prdata_timer),
        .pready_timer(pready_timer), .pslverr_timer(pslverr_timer)
    );

    apb_uart_tx u_uart (
        .clk(clk_periph), .rst_n(rst_periph_n),
        .psel(psel_uart), .penable(penable), .pwrite(pwrite),
        .paddr(paddr[3:0]), .pwdata(pwdata),
        .prdata(prdata_uart), .pready(pready_uart), .pslverr(pslverr_uart),
        .tx(uart_tx)
    );

    apb_timer u_timer (
        .clk(clk_periph), .rst_n(rst_periph_n),
        .psel(psel_timer), .penable(penable), .pwrite(pwrite),
        .paddr(paddr[3:0]), .pwdata(pwdata),
        .prdata(prdata_timer), .pready(pready_timer), .pslverr(pslverr_timer),
        .irq(irq_timer_periph)
    );

    // the interrupt is a level, so a two-flop synchronizer is enough
    sync_2ff u_irq_sync (.clk(clk_core), .rst_n(rst_core_n),
                         .d(irq_timer_periph), .q(irq_timer_core));

endmodule

`default_nettype wire
