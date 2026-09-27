// TinyTrust — lean PMP: 4 entries, NAPOT + OFF only, 1 KiB grain (D6)
//
// Documented deviations from the RISC-V privileged spec (all WARL-legal):
//   - pmpcfg.A accepts only OFF (00) and NAPOT (11); TOR/NA4 write as OFF.
//   - Grain G = 7: pmpaddr[6:0] read as ones when A=NAPOT, so the minimum
//     region is 1 KiB. Stored bits per entry: pmpaddr[29:7] (23 bits).
//   - Physical addresses are 32-bit; pmpaddr[31:30] are read-as-zero.
//
// Check semantics (spec-compliant):
//   - Lowest-numbered matching entry decides.
//   - M-mode: allowed unless a matching entry is locked and denies.
//   - U-mode: no matching entry => deny.
//   - Locked entries ignore CSR writes (both cfg byte and pmpaddr) until reset.
//
// Two check ports (P2): the multicycle core has at most one access in flight
// and uses port 1 only, tying port 2 off (yosys trims the unused checker).
// The 5-stage core (rtl/core/core_p5.v) checks a data access in MEM and an
// instruction fetch in IF in the same cycle, so it needs both. CSR state is
// shared; only the combinational match/permission chain is duplicated.

module pmp (
    input  wire        clk,
    input  wire        rst_n,

    // CSR write port (CSR read mux lives in the core's CSR file)
    input  wire        csr_we,
    input  wire [2:0]  csr_addr,   // 0: pmpcfg0, 1..4: pmpaddr0..3
    input  wire [31:0] csr_wdata,
    output wire [31:0] csr_rdata_cfg,
    output wire [31:0] csr_rdata_addr0,
    output wire [31:0] csr_rdata_addr1,
    output wire [31:0] csr_rdata_addr2,
    output wire [31:0] csr_rdata_addr3,

    input  wire        priv_m,     // 1 = M-mode, 0 = U-mode

    // access check port 1 (combinational) — data/unified
    input  wire [31:2] chk_addr,   // word-aligned physical address
    input  wire        chk_r,
    input  wire        chk_w,
    input  wire        chk_x,      // at most one of r/w/x is set
    output wire        allow,

    // access check port 2 (combinational) — instruction fetch (execute only)
    input  wire [31:2] chk2_addr,
    input  wire        chk2_x,
    output wire        allow2
);

    // ------------------------------------------------------------------
    // CSR state: per entry cfg = {L, A(1b: napot), X, W, R}, addr[29:7]
    // A is stored as one bit (0=OFF, 1=NAPOT) and expanded on read.
    // ------------------------------------------------------------------
    reg [4:0]  cfg  [0:3];   // {L, A, X, W, R}
    reg [29:7] addr [0:3];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                cfg[i]  <= 5'd0;
                addr[i] <= 23'd0;
            end
        end else if (csr_we) begin
            if (csr_addr == 3'd0) begin
                // pmpcfg0: four cfg bytes; locked entries ignore their byte.
                for (i = 0; i < 4; i = i + 1) begin
                    if (!cfg[i][4]) begin
                        cfg[i][4]   <= csr_wdata[i*8+7];                    // L
                        cfg[i][3]   <= (csr_wdata[i*8+3 +: 2] == 2'b11);    // A: NAPOT else OFF
                        cfg[i][2:0] <= csr_wdata[i*8 +: 3];                 // X, W, R
                    end
                end
            end else if (csr_addr >= 3'd1 && csr_addr <= 3'd4) begin
                if (!cfg[csr_addr - 3'd1][4])
                    addr[csr_addr - 3'd1] <= csr_wdata[29:7];
            end
        end
    end

    // CSR read views
    genvar g;
    wire [7:0] cfg_byte [0:3];
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_cfgrd
            assign cfg_byte[g] = {cfg[g][4], 2'b00,
                                  cfg[g][3] ? 2'b11 : 2'b00,
                                  cfg[g][2:0]};
        end
    endgenerate
    assign csr_rdata_cfg   = {cfg_byte[3], cfg_byte[2], cfg_byte[1], cfg_byte[0]};
    assign csr_rdata_addr0 = {2'b00, addr[0], {7{cfg[0][3]}}};
    assign csr_rdata_addr1 = {2'b00, addr[1], {7{cfg[1][3]}}};
    assign csr_rdata_addr2 = {2'b00, addr[2], {7{cfg[2][3]}}};
    assign csr_rdata_addr3 = {2'b00, addr[3], {7{cfg[3][3]}}};

    // Flatten the entry state for the checker instances (Verilog-2005 has no
    // array ports).
    wire [19:0] cfg_flat  = {cfg[3],  cfg[2],  cfg[1],  cfg[0]};
    wire [91:0] addr_flat = {addr[3], addr[2], addr[1], addr[0]};

    pmp_chk u_chk1 (
        .cfg_flat  (cfg_flat),
        .addr_flat (addr_flat),
        .priv_m    (priv_m),
        .chk_addr  (chk_addr),
        .chk_r     (chk_r),
        .chk_w     (chk_w),
        .chk_x     (chk_x),
        .allow     (allow)
    );

    pmp_chk u_chk2 (
        .cfg_flat  (cfg_flat),
        .addr_flat (addr_flat),
        .priv_m    (priv_m),
        .chk_addr  (chk2_addr),
        .chk_r     (1'b0),
        .chk_w     (1'b0),
        .chk_x     (chk2_x),
        .allow     (allow2)
    );

endmodule


// Combinational match + permission chain for one access. Pure function of the
// entry state, so it is instantiated once per concurrent access port.
module pmp_chk (
    input  wire [19:0] cfg_flat,    // 4 x {L, A, X, W, R}
    input  wire [91:0] addr_flat,   // 4 x pmpaddr[29:7]
    input  wire        priv_m,
    input  wire [31:2] chk_addr,
    input  wire        chk_r,
    input  wire        chk_w,
    input  wire        chk_x,
    output wire        allow
);
    wire [4:0]  cfg  [0:3];
    wire [22:0] addr [0:3];
    wire        match [0:3];
    wire        perm  [0:3];

    // pmpaddr semantics: pmpaddr = phys_addr[33:2]; with G=7 the low 7 bits
    // are ones, so the effective NAPOT field is {addr[29:7], 7'h7F}.
    // mask = pa ^ (pa + 1) covers the trailing-ones run plus its boundary bit.
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_match
            assign cfg[g]  = cfg_flat[g*5 +: 5];
            assign addr[g] = addr_flat[g*23 +: 23];
            wire [29:0] pa   = {addr[g], 7'h7F};
            wire [29:0] mask = pa ^ (pa + 30'd1);
            assign match[g] = cfg[g][3] &&
                              (((chk_addr[31:2] ^ pa) & ~mask) == 30'd0);
            assign perm[g]  = (chk_r & cfg[g][0]) |
                              (chk_w & cfg[g][1]) |
                              (chk_x & cfg[g][2]);
        end
    endgenerate

    // Priority: lowest-numbered matching entry decides.
    wire hit     = match[0] | match[1] | match[2] | match[3];
    wire [4:0] win = match[0] ? cfg[0] :
                     match[1] ? cfg[1] :
                     match[2] ? cfg[2] : cfg[3];
    wire win_perm  = match[0] ? perm[0] :
                     match[1] ? perm[1] :
                     match[2] ? perm[2] : perm[3];

    // M-mode: constrained only by locked matching entries.
    // U-mode: must hit a matching entry with permission.
    assign allow = priv_m ? (!hit || !win[4] || win_perm)
                          : (hit && win_perm);

endmodule
