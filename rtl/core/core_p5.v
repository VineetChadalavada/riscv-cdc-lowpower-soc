// TinyTrust — RV32I 5-stage pipelined core (docs/RETARGET.md D13, milestone P2)
//
// IF / ID / EX / MEM / WB, full EX-operand forwarding, one-cycle load-use
// stall. Architecturally identical to the multicycle core in rtl/core/core.v —
// same ISA subset, same CSR set and WARL rules, same trap causes, same RVFI
// conventions — so both cores check against the same ISS and the same
// riscv-formal suite. Only the timing differs, which is the point of P2: the
// CPI comparison is measured on identical stimulus.
//
// Structural decisions that differ from the multicycle core:
//   - Split instruction and data ports (D10 is already reversed for v2). IF
//     and MEM both want memory in the same cycle; a unified port would
//     serialize them. The SoC/TB arbitrates today; P3 hangs an I$ and a D$
//     off these two ports directly.
//   - Barrel shifter, single-cycle (reverses D5's iterative 1 bit/cycle
//     shifter). A multi-cycle EX defeats the pipeline; D5 was an area
//     decision taken under the Tiny Tapeout tile budget, which is gone.
//   - Dedicated adders per stage instead of the one shared adder (D1's
//     shared-everything datapath). IF needs PC+4 while EX computes a branch
//     target while MEM holds an effective address — sharing is not
//     expressible once the stages run concurrently.
//
// Commit point is MEM. Nothing architectural happens before it: the register
// file is written in WB, but the decision to write is made in MEM, and the
// data bus is driven in MEM only once no older instruction can still fault.
// Traps are therefore precise and in program order:
//   - IF   raises instruction access fault (PMP execute deny, bus fault)
//   - ID   raises illegal instruction, ECALL, EBREAK
//   - EX   raises load/store address misaligned, and instruction address
//          misaligned (reported on the branch/jump itself, per the spec)
//   - MEM  raises load/store access fault (PMP deny, bus fault), and is where
//          every carried exception is finally taken
//
// SYSTEM (opcode 1110011: CSR, ECALL, EBREAK, MRET, WFI) is serializing: it
// waits in ID until EX and MEM are empty, and the pipeline is flushed behind
// it when it commits. This costs a handful of cycles on a rare instruction
// and buys three things outright — CSR read-after-write ordering, a privilege
// change (MRET) that cannot be overtaken by instructions fetched under the
// old mode, and a pmpcfg/pmpaddr write that cannot be bypassed by an
// in-flight fetch checked against the old configuration. "Verifiability
// first" (v2 design principle 1) is why this is a stall and not a bypass net.
//
// RVFI is compiled out unless RISCV_FORMAL is defined, exactly as in core.v
// (it is ~21% of core area). The conventions are identical:
//   - rvfi_mem_addr is word-aligned; rmask/wmask are byte lanes; rdata/wdata
//     are full bus words (stores carry the lane-replicated bus pattern).
//   - A fetch access fault retires with rvfi_trap=1 and rvfi_insn=0.
//   - Interrupt entry produces no retire; the handler's first retired
//     instruction carries rvfi_intr=1.

module core_p5 #(
    parameter [31:0] RESET_PC = 32'h0000_0000
) (
    input  wire        clk,
    input  wire        rst_n,

    // instruction port (single outstanding valid/ready)
    output wire        imem_valid,
    output wire [31:0] imem_addr,
    input  wire        imem_ready,
    input  wire [31:0] imem_rdata,
    input  wire        imem_fault,

    // data port (single outstanding valid/ready)
    output wire        dmem_valid,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,      // nonzero = store
    input  wire        dmem_ready,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_fault,

    // interrupt lines (already synchronized at SoC level)
    input  wire        irq_timer,
    input  wire        irq_external,

    // fault hardening (§5.5): sticky until reset
    output wire        fsm_fault

`ifdef RISCV_FORMAL
    ,
    output wire        rvfi_valid,
    output wire [63:0] rvfi_order,
    output wire [31:0] rvfi_insn,
    output wire        rvfi_trap,
    output wire        rvfi_halt,
    output wire        rvfi_intr,
    output wire [1:0]  rvfi_mode,
    output wire [1:0]  rvfi_ixl,
    output wire [4:0]  rvfi_rs1_addr,
    output wire [4:0]  rvfi_rs2_addr,
    output wire [31:0] rvfi_rs1_rdata,
    output wire [31:0] rvfi_rs2_rdata,
    output wire [4:0]  rvfi_rd_addr,
    output wire [31:0] rvfi_rd_wdata,
    output wire [31:0] rvfi_pc_rdata,
    output wire [31:0] rvfi_pc_wdata,
    output wire [31:0] rvfi_mem_addr,
    output wire [3:0]  rvfi_mem_rmask,
    output wire [3:0]  rvfi_mem_wmask,
    output wire [31:0] rvfi_mem_rdata,
    output wire [31:0] rvfi_mem_wdata
`endif
);

    // exception cause codes (mcause[4:0]) — identical set to core.v
    localparam [4:0] EXC_IALIGN = 5'd0,  EXC_IFAULT = 5'd1,
                     EXC_ILL    = 5'd2,  EXC_BREAK  = 5'd3,
                     EXC_LALIGN = 5'd4,  EXC_LFAULT = 5'd5,
                     EXC_SALIGN = 5'd6,  EXC_SFAULT = 5'd7,
                     EXC_ECALLU = 5'd8,  EXC_ECALLM = 5'd11,
                     EXC_FSM    = 5'd24;   // reserved/platform: FSM fault

    // ==================================================================
    // Architectural state
    // ==================================================================
    reg        priv_m_q;      // 1 = M-mode
    reg        priv_m_shadow; // duplicated privilege state (§5.5)

    reg        mstatus_mie, mstatus_mpie, mpp_m;   // MPP stored as one bit
    reg [27:0] mtvec_base;                          // mtvec[31:4]
    reg [29:0] mepc_r;                              // mepc[31:2]
    reg        mcause_irq;
    reg [4:0]  mcause_code;
    reg [31:0] mscratch;
    reg        mie_mtie, mie_meie;

    reg        intr_flag;     // next retire is first instruction of a handler
    reg [63:0] order_cnt;
    reg        fsm_fault_sticky;

    // ==================================================================
    // Pipeline registers
    // ==================================================================
    // IF
    reg [31:0] pc_f;          // next PC to fetch
    reg [31:0] if_addr;       // address of the in-flight fetch
    reg        if_issued;     // a fetch transaction is on the bus
    reg        if_kill;       // in-flight fetch was flushed; discard its data

    // IF/ID
    reg        d_valid;
    reg [31:0] d_pc, d_insn;
    reg        d_ifault;

    // ID/EX
    reg        e_valid;
    reg [31:0] e_pc, e_insn;
    reg        e_exc;
    reg [4:0]  e_cause;
    reg        e_illegal;                 // exception was "illegal instruction"
    reg [31:0] e_rs1v, e_rs2v;            // architectural register-file reads
    reg        e_lui, e_auipc, e_jal, e_jalr, e_branch, e_load, e_store;
    reg        e_op, e_csr, e_csri, e_mret, e_sys, e_csr_wr;
    reg        e_uses_rs1, e_uses_rs2, e_uses_rd;
    reg        e_priv_m;

    // EX/MEM
    reg        m_valid;
    reg [31:0] m_pc, m_insn;
    reg        m_exc;
    reg [4:0]  m_cause;
    reg        m_irq;
    reg [4:0]  m_irq_code;
    reg [31:0] m_result;                  // final rd value for non-loads
    reg [31:0] m_addr;                    // byte effective address
    reg [31:0] m_store_wdata;
    reg [3:0]  m_lane_mask;
    reg [31:0] m_next_pc;
    reg [4:0]  m_rd;
    reg        m_uses_rd, m_load, m_store, m_csr, m_mret, m_sys, m_csr_wr;
    reg [2:0]  m_funct3;
    reg [11:0] m_csr_a;
    reg [31:0] m_csr_wval;
    reg        m_priv_m;
    reg [4:0]  m_rs1a, m_rs2a;
    reg [31:0] m_rs1d, m_rs2d;

    // MEM/WB
    reg        w_valid;                   // an instruction retires this cycle
    reg        w_fwd_live;                // WB result is still forwardable
    reg        w_trap;
    reg [63:0] w_order;
    reg [31:0] w_pc, w_insn, w_pc_wdata;
    reg        w_intr;
    reg [1:0]  w_mode;
    reg [4:0]  w_rs1a, w_rs2a, w_rd;
    reg [31:0] w_rs1d, w_rs2d;
    reg        w_uses_rd, w_is_load;
    reg [31:0] w_alu;                     // non-load rd value
    reg [31:0] w_memword;                 // raw data-bus word
    reg [1:0]  w_memoff;
    reg [2:0]  w_funct3;
    reg [31:0] w_mem_addr, w_mem_rdata, w_mem_wdata;
    reg [3:0]  w_mem_rmask, w_mem_wmask;

    // ==================================================================
    // ID: decode (field-for-field the same rules as core.v)
    // ==================================================================
    wire [6:0]  d_opc  = d_insn[6:0];
    wire [4:0]  d_rd   = d_insn[11:7];
    wire [2:0]  d_f3   = d_insn[14:12];
    wire [4:0]  d_rs1  = d_insn[19:15];
    wire [4:0]  d_rs2  = d_insn[24:20];
    wire [6:0]  d_f7   = d_insn[31:25];
    wire [11:0] d_csra = d_insn[31:20];

    wire d_opimm_legal = (d_f3 == 3'b001) ? (d_f7 == 7'b0000000) :
                         (d_f3 == 3'b101) ? (d_f7 == 7'b0000000 ||
                                             d_f7 == 7'b0100000) : 1'b1;
    wire d_op_legal = (d_f7 == 7'b0000000) ? 1'b1 :
                      (d_f7 == 7'b0100000) ? (d_f3 == 3'b000 ||
                                              d_f3 == 3'b101) : 1'b0;

    wire d_is_lui    = (d_opc == 7'b0110111);
    wire d_is_auipc  = (d_opc == 7'b0010111);
    wire d_is_jal    = (d_opc == 7'b1101111);
    wire d_is_jalr   = (d_opc == 7'b1100111) && (d_f3 == 3'b000);
    wire d_is_branch = (d_opc == 7'b1100011) && (d_f3 != 3'b010)
                                             && (d_f3 != 3'b011);
    wire d_is_load   = (d_opc == 7'b0000011) && (d_f3 != 3'b011)
                       && (d_f3 != 3'b110) && (d_f3 != 3'b111);
    wire d_is_store  = (d_opc == 7'b0100011) && (d_f3[2] == 1'b0)
                                             && (d_f3 != 3'b011);
    wire d_is_opimm  = (d_opc == 7'b0010011) && d_opimm_legal;
    wire d_is_op     = (d_opc == 7'b0110011) && d_op_legal;
    wire d_is_fence  = (d_opc == 7'b0001111) && (d_f3 == 3'b000);  // FENCE=NOP

    wire d_is_system = (d_opc == 7'b1110011);
    wire d_is_csr    = d_is_system && (d_f3 != 3'b000) && (d_f3 != 3'b100);
    wire d_is_csri   = d_is_csr && d_f3[2];
    wire d_is_ecall  = (d_insn == 32'h0000_0073);
    wire d_is_ebreak = (d_insn == 32'h0010_0073);
    wire d_is_mret   = (d_insn == 32'h3020_0073);
    wire d_is_wfi    = (d_insn == 32'h1050_0073);                  // WFI=NOP
    wire d_sys_priv_ok = d_is_ecall | d_is_ebreak | d_is_wfi
                       | (d_is_mret && priv_m_q);

    wire d_uses_rs1 = d_is_op | d_is_opimm | d_is_load | d_is_store
                    | d_is_branch | d_is_jalr | (d_is_csr && !d_is_csri);
    wire d_uses_rs2 = d_is_op | d_is_store | d_is_branch;
    wire d_uses_rd  = d_is_lui | d_is_auipc | d_is_jal | d_is_jalr | d_is_load
                    | d_is_op | d_is_opimm | d_is_csr;

    // CSR address decode, shared by the ID legality check and the EX read mux.
    function csr_exists(input [11:0] a);
        csr_exists = (a == 12'h300) || (a == 12'h301) || (a == 12'h304)
                  || (a == 12'h305) || (a == 12'h340) || (a == 12'h341)
                  || (a == 12'h342) || (a == 12'h344) || (a == 12'h3A0)
                  || (a >= 12'h3B0 && a <= 12'h3B3)
                  || (a >= 12'hF11 && a <= 12'hF14);
    endfunction

    wire d_csr_do_write = (d_f3[1:0] == 2'b01) || (d_rs1 != 5'd0);
    wire d_csr_illegal  = d_is_csr && (!csr_exists(d_csra)
                                       || (d_csr_do_write
                                           && d_csra[11:10] == 2'b11)
                                       || !priv_m_q);

    wire d_decode_ok = d_is_lui | d_is_auipc | d_is_jal | d_is_jalr
                     | d_is_branch | d_is_load | d_is_store | d_is_opimm
                     | d_is_op | d_is_fence
                     | (d_is_csr && !d_csr_illegal)
                     | (d_is_system && d_f3 == 3'b000 && d_sys_priv_ok);
    wire d_illegal = !d_decode_ok;

    // A fetch fault outranks decode: the instruction word is not trustworthy,
    // so it reports insn=0 with cause 1 and is never decoded (core.v takes the
    // same path straight out of S_FETCH, bypassing S_EX).
    wire       d_exc    = d_ifault | d_illegal;
    wire [4:0] d_cause  = d_ifault ? EXC_IFAULT : EXC_ILL;
    wire [4:0] d_ecause = d_is_ecall ? (priv_m_q ? EXC_ECALLM : EXC_ECALLU)
                                     : EXC_BREAK;

    // ==================================================================
    // Register file (write-through: see regfile.v WRITE_THROUGH)
    // ==================================================================
    wire [31:0] rf_rdata1, rf_rdata2;
    wire [31:0] wb_val;
    wire        rf_we;

    regfile #(.WRITE_THROUGH(1)) u_regfile (
        .clk    (clk),
        .we     (rf_we),
        .waddr  (w_rd),
        .wdata  (wb_val),
        .raddr1 (d_rs1),
        .rdata1 (rf_rdata1),
        .raddr2 (d_rs2),
        .rdata2 (rf_rdata2)
    );

    // ==================================================================
    // EX: operand select and forwarding
    // ==================================================================
    wire [4:0] e_rs1a = e_insn[19:15];
    wire [4:0] e_rs2a = e_insn[24:20];
    wire [4:0] e_rd   = e_insn[11:7];
    wire [2:0] e_f3   = e_insn[14:12];

    // The MEM producer is the younger of the two, so it wins. A load is never
    // forwarded from MEM — its data has not returned yet, which is exactly
    // what the load-use stall exists to cover.
    wire m_fwd_ok = m_valid && !m_exc && !m_irq && m_uses_rd
                 && (m_rd != 5'd0) && !m_load;
    // w_fwd_live, not w_valid: the WB result must stay visible to EX for as
    // long as EX cannot advance, not just for the one cycle it retires in.
    // A consumer enters EX on the cycle its producer is in WB, having read
    // the register file one cycle too early to see the write; if the
    // instruction between them is a load or store, MEM stalls and the
    // consumer is pinned in EX for the whole transaction. With a single-cycle
    // window the forward vanishes underneath it and it captures a stale
    // operand. w_fwd_live holds until the next instruction reaches WB, so it
    // always names the most recent architectural register write — which makes
    // forwarding from it correct at any point during the hold. See BUG-005.
    wire w_fwd_ok = w_fwd_live && !w_trap && w_uses_rd && (w_rd != 5'd0);

    wire [31:0] ex_rs1 = (m_fwd_ok && m_rd == e_rs1a) ? m_result
                       : (w_fwd_ok && w_rd == e_rs1a) ? wb_val
                                                      : e_rs1v;
    wire [31:0] ex_rs2 = (m_fwd_ok && m_rd == e_rs2a) ? m_result
                       : (w_fwd_ok && w_rd == e_rs2a) ? wb_val
                                                      : e_rs2v;

    wire [31:0] e_imm_i = {{20{e_insn[31]}}, e_insn[31:20]};
    wire [31:0] e_imm_s = {{20{e_insn[31]}}, e_insn[31:25], e_insn[11:7]};
    wire [31:0] e_imm_b = {{19{e_insn[31]}}, e_insn[31], e_insn[7],
                           e_insn[30:25], e_insn[11:8], 1'b0};
    wire [31:0] e_imm_u = {e_insn[31:12], 12'b0};
    wire [31:0] e_imm_j = {{11{e_insn[31]}}, e_insn[31], e_insn[19:12],
                           e_insn[20], e_insn[30:21], 1'b0};

    // ---- ALU (barrel shifter; reverses D5) ----
    wire [31:0] alu_b   = e_op ? ex_rs2 : e_imm_i;
    wire        alu_sub = e_op && e_insn[30] && (e_f3 == 3'b000);
    wire [4:0]  shamt   = e_op ? ex_rs2[4:0] : e_insn[24:20];

    // The arithmetic shift is computed into its own signed wire: inside a
    // ternary, Verilog makes the whole expression unsigned if either arm is,
    // and that signedness propagates back down into the operands, silently
    // turning `>>>` into a logical shift. (Caught by SRA/SRAI lockstep
    // mismatches on the first p5 co-sim run — see docs/BUGLOG.md.)
    wire signed [31:0] sra_res = $signed(ex_rs1) >>> shamt;

    reg [31:0] alu_res;
    always @* begin
        case (e_f3)
            3'b000:  alu_res = alu_sub ? (ex_rs1 - alu_b) : (ex_rs1 + alu_b);
            3'b001:  alu_res = ex_rs1 << shamt;
            3'b010:  alu_res = {31'd0, ($signed(ex_rs1) < $signed(alu_b))};
            3'b011:  alu_res = {31'd0, (ex_rs1 < alu_b)};
            3'b100:  alu_res = ex_rs1 ^ alu_b;
            3'b101:  alu_res = e_insn[30] ? sra_res : (ex_rs1 >> shamt);
            3'b110:  alu_res = ex_rs1 | alu_b;
            default: alu_res = ex_rs1 & alu_b;
        endcase
    end

    // ---- branch condition ----
    wire br_eq  = (ex_rs1 == ex_rs2);
    wire br_lt  = ($signed(ex_rs1) < $signed(ex_rs2));
    wire br_ltu = (ex_rs1 < ex_rs2);
    reg  br_cond;
    always @* begin
        case (e_f3)
            3'b000:  br_cond = br_eq;
            3'b001:  br_cond = !br_eq;
            3'b100:  br_cond = br_lt;
            3'b101:  br_cond = !br_lt;
            3'b110:  br_cond = br_ltu;
            default: br_cond = !br_ltu;              // 111 = BGEU
        endcase
    end

    // ---- control transfer ----
    wire [31:0] e_pc4     = e_pc + 32'd4;
    wire        br_taken  = e_branch && br_cond;
    wire [31:0] e_nextpc  = e_jal    ? (e_pc + e_imm_j)
                          : e_jalr   ? ((ex_rs1 + e_imm_i) & ~32'd1)
                          : br_taken ? (e_pc + e_imm_b)
                                     : e_pc4;
    wire e_ctl_xfer   = e_jal | e_jalr | br_taken;
    wire e_target_mis = e_ctl_xfer && (e_nextpc[1:0] != 2'b00);

    // ---- load/store address and lanes ----
    wire [31:0] ls_addr = ex_rs1 + (e_store ? e_imm_s : e_imm_i);
    wire ls_mis = (e_f3[1:0] == 2'b01 && ls_addr[0])
                | (e_f3[1:0] == 2'b10 && ls_addr[1:0] != 2'b00);

    reg [3:0]  lane_mask;
    reg [31:0] store_wdata;
    always @* begin
        case (e_f3[1:0])
            2'b00: begin
                lane_mask   = 4'b0001 << ls_addr[1:0];
                store_wdata = {4{ex_rs2[7:0]}};
            end
            2'b01: begin
                lane_mask   = ls_addr[1] ? 4'b1100 : 4'b0011;
                store_wdata = {2{ex_rs2[15:0]}};
            end
            default: begin
                lane_mask   = 4'b1111;
                store_wdata = ex_rs2;
            end
        endcase
    end

    // ---- CSR read (EX) and write value ----
    wire [11:0] e_csra = e_insn[31:20];
    wire [31:0] pmp_cfg_rd, pmp_a0_rd, pmp_a1_rd, pmp_a2_rd, pmp_a3_rd;

    wire mip_mtip = irq_timer;
    wire mip_meip = irq_external;
    wire [31:0] mstatus_rd = {19'd0, {2{mpp_m}}, 3'd0, mstatus_mpie,
                              3'd0, mstatus_mie, 3'd0};
    wire [31:0] mie_rd     = {20'd0, mie_meie, 3'd0, mie_mtie, 7'd0};
    wire [31:0] mip_rd     = {20'd0, mip_meip, 3'd0, mip_mtip, 7'd0};

    reg [31:0] csr_rdata;
    always @* begin
        case (e_csra)
            12'h300: csr_rdata = mstatus_rd;
            12'h301: csr_rdata = 32'd0;                    // misa: read 0
            12'h304: csr_rdata = mie_rd;
            12'h305: csr_rdata = {mtvec_base, 4'd0};
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = {mepc_r, 2'd0};
            12'h342: csr_rdata = {mcause_irq, 26'd0, mcause_code};
            12'h344: csr_rdata = mip_rd;
            12'h3A0: csr_rdata = pmp_cfg_rd;
            12'h3B0: csr_rdata = pmp_a0_rd;
            12'h3B1: csr_rdata = pmp_a1_rd;
            12'h3B2: csr_rdata = pmp_a2_rd;
            12'h3B3: csr_rdata = pmp_a3_rd;
            default: csr_rdata = 32'd0;   // mvendorid/marchid/mimpid/mhartid
        endcase
    end

    wire [31:0] csr_wsrc = e_csri ? {27'd0, e_rs1a} : ex_rs1;
    wire [31:0] csr_wval = (e_f3[1:0] == 2'b01) ? csr_wsrc
                         : (e_f3[1:0] == 2'b10) ? (csr_rdata |  csr_wsrc)
                                                : (csr_rdata & ~csr_wsrc);

    // ---- EX result for everything except loads ----
    wire [31:0] ex_result = e_lui          ? e_imm_u
                          : e_auipc        ? (e_pc + e_imm_u)
                          : (e_jal|e_jalr) ? e_pc4
                          : e_csr          ? csr_rdata
                                           : alu_res;

    // ---- exception raised in EX ----
    wire       ex_exc_new   = e_valid && !e_exc
                            && (e_target_mis || ((e_load|e_store) && ls_mis));
    wire [4:0] ex_cause_new = e_target_mis ? EXC_IALIGN
                            : e_store      ? EXC_SALIGN : EXC_LALIGN;

    // ==================================================================
    // MEM: data access, trap resolution, CSR commit
    // ==================================================================
    wire pmp_allow_d, pmp_allow_x;

    wire m_is_mem = m_valid && !m_exc && !m_irq && (m_load | m_store);

    assign dmem_valid = m_is_mem && pmp_allow_d;
    assign dmem_addr  = {m_addr[31:2], 2'd0};
    assign dmem_wdata = m_store_wdata;
    assign dmem_wstrb = m_store ? m_lane_mask : 4'd0;

    wire mem_busy  = dmem_valid && !dmem_ready;
    wire m_acc_flt = m_is_mem && (!pmp_allow_d || (dmem_ready && dmem_fault));

    wire       m_irq_take    = m_valid && m_irq;
    wire       m_exc_final   = m_valid && !m_irq && (m_exc || m_acc_flt);
    wire [4:0] m_cause_final = m_exc ? m_cause
                             : (m_store ? EXC_SFAULT : EXC_LFAULT);

    wire [31:0] mtvec_pc = {mtvec_base, 4'd0};
    wire [31:0] m_target = (m_exc_final || m_irq_take) ? mtvec_pc
                         : m_mret                      ? {mepc_r, 2'd0}
                                                       : m_next_pc;

    // ==================================================================
    // Stall / advance / flush
    //
    // A stage "advances" when its contents move on this cycle. MEM is the
    // only stage that can stall (a data-bus transaction), and it back-
    // pressures everything above it. ID additionally holds for the two
    // hazards below, inserting a bubble into EX.
    // ==================================================================
    wire mem_advance = !mem_busy;                          // MEM -> WB
    wire ex_advance  = mem_advance;                        // EX  -> MEM

    // load-use: the producer is in EX, its data does not exist until WB
    wire load_use = d_valid && e_valid && e_load && (e_rd != 5'd0)
                 && ((d_uses_rs1 && d_rs1 == e_rd)
                  || (d_uses_rs2 && d_rs2 == e_rd));
    // SYSTEM serialization (see header): drain EX and MEM before issuing
    wire sys_wait = d_valid && d_is_system && (e_valid || m_valid);

    wire id_advance = ex_advance && !(load_use || sys_wait);   // ID -> EX

    wire fsm_fault_now = (priv_m_q != priv_m_shadow);

    wire mem_redirect = mem_advance && m_valid
                     && (m_exc_final || m_irq_take || m_sys);
    wire ex_redirect  = ex_advance && e_valid && !e_exc
                     && e_ctl_xfer && !e_target_mis;

    // A redirect out of EX is wrong-path only for what is *behind* the
    // branch: the branch itself still commits. A redirect out of MEM
    // additionally kills EX. Only the hardening trap kills MEM.
    wire flush_id  = fsm_fault_now || mem_redirect || ex_redirect;
    wire flush_ex  = fsm_fault_now || mem_redirect;

    wire m_retire   = mem_advance && m_valid && !m_irq_take && !fsm_fault_now;
    wire m_trap_now = mem_advance && (m_exc_final || m_irq_take);
    wire m_commit   = m_retire && !m_exc_final;

    // ==================================================================
    // IF
    // ==================================================================
    wire if_can_accept = !d_valid || id_advance;
    wire if_start      = !if_issued && if_can_accept && !flush_id;
    wire if_go         = if_start && pmp_allow_x;
    wire if_fault_now  = if_start && !pmp_allow_x;   // PMP deny: no bus cycle

    assign imem_valid = if_issued || if_go;
    assign imem_addr  = if_issued ? if_addr : pc_f;

    wire        fetch_done = imem_valid && imem_ready;
    wire [31:0] fetch_pc   = if_issued ? if_addr : pc_f;
    wire        fetch_bad  = fetch_done && imem_fault;
    wire        fetch_land = (fetch_done && !if_kill && !flush_id)
                           || if_fault_now;

    // ==================================================================
    // PMP — data check in MEM, instruction check in IF, same cycle
    // ==================================================================
    wire pmp_csr_we = m_commit && m_csr && m_csr_wr
                   && ((m_csr_a == 12'h3A0)
                       || (m_csr_a >= 12'h3B0 && m_csr_a <= 12'h3B3));
    wire [2:0] pmp_csr_i = (m_csr_a == 12'h3A0) ? 3'd0
                                                : (3'd1 + {1'b0, m_csr_a[1:0]});

    pmp u_pmp (
        .clk             (clk),
        .rst_n           (rst_n),
        .csr_we          (pmp_csr_we),
        .csr_addr        (pmp_csr_i),
        .csr_wdata       (m_csr_wval),
        .csr_rdata_cfg   (pmp_cfg_rd),
        .csr_rdata_addr0 (pmp_a0_rd),
        .csr_rdata_addr1 (pmp_a1_rd),
        .csr_rdata_addr2 (pmp_a2_rd),
        .csr_rdata_addr3 (pmp_a3_rd),
        .priv_m          (priv_m_q),
        .chk_addr        (m_addr[31:2]),
        .chk_r           (m_is_mem && m_load),
        .chk_w           (m_is_mem && m_store),
        .chk_x           (1'b0),
        .allow           (pmp_allow_d),
        .chk2_addr       (pc_f[31:2]),
        .chk2_x          (1'b1),
        .allow2          (pmp_allow_x)
    );

    // ==================================================================
    // Interrupts — sampled as an instruction enters MEM, i.e. before it can
    // have any side effect (the store bus cycle and the CSR write both live
    // in MEM). core.v samples at the fetch boundary instead; both give a
    // precise entry with no retire for the preempted instruction.
    // ==================================================================
    wire meip_pend = mip_meip && mie_meie;
    wire mtip_pend = mip_mtip && mie_mtie;
    wire irq_take  = (meip_pend || mtip_pend)
                   && (priv_m_q ? mstatus_mie : 1'b1);
    wire [4:0] irq_code = meip_pend ? 5'd11 : 5'd7;

    // ==================================================================
    // WB
    // ==================================================================
    wire [31:0] lw_shifted = w_memword >> {w_memoff, 3'b000};
    reg  [31:0] load_val;
    always @* begin
        case (w_funct3)
            3'b000:  load_val = {{24{lw_shifted[7]}},  lw_shifted[7:0]};
            3'b100:  load_val = {24'd0,                lw_shifted[7:0]};
            3'b001:  load_val = {{16{lw_shifted[15]}}, lw_shifted[15:0]};
            3'b101:  load_val = {16'd0,                lw_shifted[15:0]};
            default: load_val = w_memword;
        endcase
    end

    assign wb_val = w_is_load ? load_val : w_alu;
    assign rf_we  = w_valid && !w_trap && w_uses_rd && (w_rd != 5'd0);

    assign fsm_fault = fsm_fault_now || fsm_fault_sticky;

`ifdef RISCV_FORMAL
    assign rvfi_halt      = 1'b0;
    assign rvfi_ixl       = 2'b01;
    assign rvfi_valid     = w_valid;
    assign rvfi_order     = w_order;
    assign rvfi_insn      = w_insn;
    assign rvfi_trap      = w_trap;
    assign rvfi_intr      = w_intr;
    assign rvfi_mode      = w_mode;
    assign rvfi_pc_rdata  = w_pc;
    assign rvfi_pc_wdata  = w_pc_wdata;
    assign rvfi_rs1_addr  = w_rs1a;
    assign rvfi_rs1_rdata = w_rs1d;
    assign rvfi_rs2_addr  = w_rs2a;
    assign rvfi_rs2_rdata = w_rs2d;
    assign rvfi_rd_addr   = (!w_trap && w_uses_rd) ? w_rd : 5'd0;
    assign rvfi_rd_wdata  = (!w_trap && w_uses_rd && w_rd != 5'd0) ? wb_val
                                                                   : 32'd0;
    assign rvfi_mem_addr  = w_mem_addr;
    assign rvfi_mem_rmask = w_mem_rmask;
    assign rvfi_mem_wmask = w_mem_wmask;
    assign rvfi_mem_rdata = w_mem_rdata;
    assign rvfi_mem_wdata = w_mem_wdata;
`endif

    // ==================================================================
    // Sequential
    // ==================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_f          <= RESET_PC;
            if_addr       <= 32'd0;
            if_issued     <= 1'b0;
            if_kill       <= 1'b0;
            d_valid       <= 1'b0;
            d_pc          <= 32'd0;
            d_insn        <= 32'd0;
            d_ifault      <= 1'b0;
            e_valid       <= 1'b0;
            m_valid       <= 1'b0;
            m_exc         <= 1'b0;
            m_irq         <= 1'b0;
            m_load        <= 1'b0;
            m_store       <= 1'b0;
            m_uses_rd     <= 1'b0;
            m_rd          <= 5'd0;
            w_valid       <= 1'b0;
            w_fwd_live    <= 1'b0;
            w_trap        <= 1'b0;
            w_uses_rd     <= 1'b0;
            w_is_load     <= 1'b0;
            w_rd          <= 5'd0;
            priv_m_q      <= 1'b1;
            priv_m_shadow <= 1'b1;
            mstatus_mie   <= 1'b0;
            mstatus_mpie  <= 1'b0;
            mpp_m         <= 1'b0;
            mtvec_base    <= 28'd0;
            mepc_r        <= 30'd0;
            mcause_irq    <= 1'b0;
            mcause_code   <= 5'd0;
            mscratch      <= 32'd0;
            mie_mtie      <= 1'b0;
            mie_meie      <= 1'b0;
            intr_flag     <= 1'b0;
            order_cnt     <= 64'd0;
            fsm_fault_sticky <= 1'b0;
        end else begin
            // ---------------------------------------------------------- IF
            if (fetch_done) begin
                if_issued <= 1'b0;
                if_kill   <= 1'b0;
            end else begin
                if (if_go) begin
                    if_issued <= 1'b1;
                    if_addr   <= pc_f;
                end
                if (flush_id && if_issued)
                    if_kill <= 1'b1;
            end

            // next fetch address: a redirect always wins over sequencing
            if (fsm_fault_now)
                pc_f <= mtvec_pc;
            else if (mem_redirect)
                pc_f <= m_target;
            else if (ex_redirect)
                pc_f <= e_nextpc;
            else if (fetch_land)
                pc_f <= fetch_pc + 32'd4;

            // ------------------------------------------------------- IF/ID
            if (flush_id)
                d_valid <= 1'b0;
            else if (fetch_land) begin
                d_valid  <= 1'b1;
                d_pc     <= fetch_pc;
                d_insn   <= (if_fault_now || fetch_bad) ? 32'd0 : imem_rdata;
                d_ifault <= if_fault_now || fetch_bad;
            end else if (d_valid && id_advance)
                d_valid <= 1'b0;

            // ------------------------------------------------------- ID/EX
            if (ex_advance) begin
                e_valid    <= d_valid && id_advance && !flush_id;
                e_pc       <= d_pc;
                e_insn     <= d_insn;
                e_exc      <= d_exc || d_is_ecall || d_is_ebreak;
                e_cause    <= d_exc ? d_cause : d_ecause;
                e_illegal  <= d_illegal;
                e_rs1v     <= rf_rdata1;
                e_rs2v     <= rf_rdata2;
                e_lui      <= d_is_lui;
                e_auipc    <= d_is_auipc;
                e_jal      <= d_is_jal;
                e_jalr     <= d_is_jalr;
                e_branch   <= d_is_branch;
                e_load     <= d_is_load   && !d_exc;
                e_store    <= d_is_store  && !d_exc;
                e_op       <= d_is_op;
                e_csr      <= d_is_csr    && !d_exc;
                e_csri     <= d_is_csri;
                e_mret     <= d_is_mret   && !d_exc;
                e_sys      <= d_is_system && !d_ifault;
                e_csr_wr   <= d_csr_do_write;
                e_uses_rs1 <= d_uses_rs1;
                e_uses_rs2 <= d_uses_rs2;
                e_uses_rd  <= d_uses_rd && !d_exc;
                e_priv_m   <= priv_m_q;
            end else if (flush_ex)
                e_valid <= 1'b0;

            // ------------------------------------------------------ EX/MEM
            if (ex_advance) begin
                m_valid       <= e_valid && !flush_ex;
                m_pc          <= e_pc;
                m_insn        <= e_insn;
                m_exc         <= e_exc || ex_exc_new;
                m_cause       <= e_exc ? e_cause : ex_cause_new;
                m_irq         <= e_valid && irq_take;
                m_irq_code    <= irq_code;
                m_result      <= ex_result;
                m_addr        <= ls_addr;
                m_store_wdata <= store_wdata;
                m_lane_mask   <= lane_mask;
                m_next_pc     <= e_nextpc;
                m_rd          <= e_rd;
                m_uses_rd     <= e_uses_rd && !ex_exc_new;
                m_load        <= e_load  && !ex_exc_new;
                m_store       <= e_store && !ex_exc_new;
                m_csr         <= e_csr;
                m_mret        <= e_mret;
                m_sys         <= e_sys;
                m_csr_wr      <= e_csr_wr;
                m_funct3      <= e_f3;
                m_csr_a       <= e_csra;
                m_csr_wval    <= csr_wval;
                m_priv_m      <= e_priv_m;
                // RVFI operand report: illegal instructions report zeros,
                // since their register fields may not name real sources.
                m_rs1a        <= (e_uses_rs1 && !e_illegal) ? e_rs1a : 5'd0;
                m_rs1d        <= (e_uses_rs1 && !e_illegal) ? ex_rs1 : 32'd0;
                m_rs2a        <= (e_uses_rs2 && !e_illegal) ? e_rs2a : 5'd0;
                m_rs2d        <= (e_uses_rs2 && !e_illegal) ? ex_rs2 : 32'd0;
            end else if (fsm_fault_now)
                m_valid <= 1'b0;

            // ------------------------------------------------------ MEM/WB
            if (mem_advance) begin
                w_valid     <= m_retire;
                w_trap      <= m_exc_final;
                w_order     <= order_cnt;
                w_pc        <= m_pc;
                w_insn      <= m_insn;
                w_pc_wdata  <= m_target;
                w_intr      <= intr_flag;
                w_mode      <= m_priv_m ? 2'd3 : 2'd0;
                w_rs1a      <= m_rs1a;
                w_rs1d      <= m_rs1d;
                w_rs2a      <= m_rs2a;
                w_rs2d      <= m_rs2d;
                w_rd        <= m_rd;
                w_uses_rd   <= m_uses_rd;
                w_is_load   <= m_load && !m_exc_final;
                w_alu       <= m_result;
                w_memword   <= dmem_rdata;
                w_memoff    <= m_addr[1:0];
                w_funct3    <= m_funct3;
                w_mem_addr  <= (m_is_mem && !m_exc_final)
                               ? {m_addr[31:2], 2'd0} : 32'd0;
                w_mem_rmask <= (m_is_mem && m_load  && !m_exc_final)
                               ? m_lane_mask : 4'd0;
                w_mem_wmask <= (m_is_mem && m_store && !m_exc_final)
                               ? m_lane_mask : 4'd0;
                w_mem_rdata <= (m_is_mem && m_load  && !m_exc_final)
                               ? dmem_rdata : 32'd0;
                w_mem_wdata <= (m_is_mem && m_store && !m_exc_final)
                               ? m_store_wdata : 32'd0;
            end else
                w_valid <= 1'b0;

            // Retire is a one-cycle pulse (RVFI and the register-file write);
            // forwardability is not. w_fwd_live is written only when MEM
            // advances, so it holds the last committed result for as long as
            // the pipeline is stalled behind a data access.
            if (mem_advance)
                w_fwd_live <= m_retire;

            if (m_retire)
                order_cnt <= order_cnt + 64'd1;

            // ---------------------------------------- architectural commit
            if (fsm_fault_now) begin
                // §5.5: corrupted control state -> forced trap, sticky alert,
                // no retire (mirrors core.v's S_TRAP entry with trap_irq=1).
                fsm_fault_sticky <= 1'b1;
                mepc_r        <= m_valid ? m_pc[31:2] : pc_f[31:2];
                mcause_irq    <= 1'b1;
                mcause_code   <= EXC_FSM;
                mstatus_mpie  <= mstatus_mie;
                mstatus_mie   <= 1'b0;
                mpp_m         <= priv_m_q;
                priv_m_q      <= 1'b1;
                priv_m_shadow <= 1'b1;
                intr_flag     <= 1'b1;
            end else if (m_trap_now) begin
                mepc_r        <= m_pc[31:2];
                mcause_irq    <= m_irq_take;
                mcause_code   <= m_irq_take ? m_irq_code : m_cause_final;
                mstatus_mpie  <= mstatus_mie;
                mstatus_mie   <= 1'b0;
                mpp_m         <= priv_m_q;
                priv_m_q      <= 1'b1;
                priv_m_shadow <= 1'b1;
                intr_flag     <= 1'b1;
            end else if (m_commit) begin
                intr_flag <= 1'b0;
                if (m_mret) begin
                    mstatus_mie   <= mstatus_mpie;
                    mstatus_mpie  <= 1'b1;
                    priv_m_q      <= mpp_m;
                    priv_m_shadow <= mpp_m;
                    mpp_m         <= 1'b0;
                end else if (m_csr && m_csr_wr) begin
                    case (m_csr_a)
                        12'h300: begin
                            mstatus_mie  <= m_csr_wval[3];
                            mstatus_mpie <= m_csr_wval[7];
                            mpp_m        <= (m_csr_wval[12:11] == 2'b11);
                        end
                        12'h304: begin
                            mie_mtie <= m_csr_wval[7];
                            mie_meie <= m_csr_wval[11];
                        end
                        12'h305: mtvec_base <= m_csr_wval[31:4];
                        12'h340: mscratch   <= m_csr_wval;
                        12'h341: mepc_r     <= m_csr_wval[31:2];
                        12'h342: begin
                            mcause_irq  <= m_csr_wval[31];
                            mcause_code <= m_csr_wval[4:0];
                        end
                        // 301 misa, 344 mip: writes ignored
                        // 3A0/3B0-3B3 handled inside pmp.v
                        default: ;
                    endcase
                end
            end
        end
    end

endmodule
