// TinyTrust -- a tiny RV32I assembler for testbenches.
//
// Directed tests want short, exact instruction sequences: "a load, then an
// instruction that uses its result straight away". Writing those as hex is
// unreadable and going through a real assembler hides the sequence behind a
// build step. These functions turn one line of SystemVerilog into one
// instruction word, so the test reads like assembly:
//
//     emit(ADDI(1, 0, 5));      // addi x1, x0, 5
//     emit(ADD (2, 1, 1));      // add  x2, x1, x1
//
// Only the RV32I instructions the unit tests use are here. The encodings are
// checked against known-good words by selftest(), which each testbench calls
// first -- a wrong encoder would otherwise make a correct core look broken.

package rv_asm_pkg;

    localparam logic [6:0] OP_LUI    = 7'b0110111,
                           OP_AUIPC  = 7'b0010111,
                           OP_JAL    = 7'b1101111,
                           OP_JALR   = 7'b1100111,
                           OP_BRANCH = 7'b1100011,
                           OP_LOAD   = 7'b0000011,
                           OP_STORE  = 7'b0100011,
                           OP_IMM    = 7'b0010011,
                           OP_OP     = 7'b0110011,
                           OP_SYSTEM = 7'b1110011;

    // ---- the six instruction formats --------------------------------------
    function automatic logic [31:0] enc_r(logic [6:0] f7, int rs2, int rs1,
                                          logic [2:0] f3, int rd, logic [6:0] op);
        return {f7, 5'(rs2), 5'(rs1), f3, 5'(rd), op};
    endfunction

    function automatic logic [31:0] enc_i(int imm, int rs1, logic [2:0] f3,
                                          int rd, logic [6:0] op);
        logic [11:0] i = 12'(imm);
        return {i, 5'(rs1), f3, 5'(rd), op};
    endfunction

    function automatic logic [31:0] enc_s(int imm, int rs2, int rs1,
                                          logic [2:0] f3, logic [6:0] op);
        logic [11:0] i = 12'(imm);
        return {i[11:5], 5'(rs2), 5'(rs1), f3, i[4:0], op};
    endfunction

    function automatic logic [31:0] enc_b(int imm, int rs2, int rs1,
                                          logic [2:0] f3, logic [6:0] op);
        logic [12:0] i = 13'(imm);
        return {i[12], i[10:5], 5'(rs2), 5'(rs1), f3, i[4:1], i[11], op};
    endfunction

    function automatic logic [31:0] enc_u(int imm20, int rd, logic [6:0] op);
        return {20'(imm20), 5'(rd), op};
    endfunction

    function automatic logic [31:0] enc_j(int imm, int rd, logic [6:0] op);
        logic [20:0] i = 21'(imm);
        return {i[20], i[10:1], i[11], i[19:12], 5'(rd), op};
    endfunction

    // ---- instructions ------------------------------------------------------
    // Argument order follows assembly: destination first.
    function automatic logic [31:0] LUI  (int rd, int imm20);           return enc_u(imm20, rd, OP_LUI);                 endfunction
    function automatic logic [31:0] AUIPC(int rd, int imm20);           return enc_u(imm20, rd, OP_AUIPC);               endfunction
    function automatic logic [31:0] JAL  (int rd, int off);             return enc_j(off, rd, OP_JAL);                   endfunction
    function automatic logic [31:0] JALR (int rd, int rs1, int off);    return enc_i(off, rs1, 3'b000, rd, OP_JALR);     endfunction

    function automatic logic [31:0] BEQ  (int rs1, int rs2, int off);   return enc_b(off, rs2, rs1, 3'b000, OP_BRANCH);  endfunction
    function automatic logic [31:0] BNE  (int rs1, int rs2, int off);   return enc_b(off, rs2, rs1, 3'b001, OP_BRANCH);  endfunction
    function automatic logic [31:0] BLT  (int rs1, int rs2, int off);   return enc_b(off, rs2, rs1, 3'b100, OP_BRANCH);  endfunction
    function automatic logic [31:0] BGEU (int rs1, int rs2, int off);   return enc_b(off, rs2, rs1, 3'b111, OP_BRANCH);  endfunction

    function automatic logic [31:0] LB   (int rd, int rs1, int off);    return enc_i(off, rs1, 3'b000, rd, OP_LOAD);     endfunction
    function automatic logic [31:0] LH   (int rd, int rs1, int off);    return enc_i(off, rs1, 3'b001, rd, OP_LOAD);     endfunction
    function automatic logic [31:0] LW   (int rd, int rs1, int off);    return enc_i(off, rs1, 3'b010, rd, OP_LOAD);     endfunction
    function automatic logic [31:0] LBU  (int rd, int rs1, int off);    return enc_i(off, rs1, 3'b100, rd, OP_LOAD);     endfunction
    function automatic logic [31:0] LHU  (int rd, int rs1, int off);    return enc_i(off, rs1, 3'b101, rd, OP_LOAD);     endfunction

    function automatic logic [31:0] SB   (int rs2, int rs1, int off);   return enc_s(off, rs2, rs1, 3'b000, OP_STORE);   endfunction
    function automatic logic [31:0] SH   (int rs2, int rs1, int off);   return enc_s(off, rs2, rs1, 3'b001, OP_STORE);   endfunction
    function automatic logic [31:0] SW   (int rs2, int rs1, int off);   return enc_s(off, rs2, rs1, 3'b010, OP_STORE);   endfunction

    function automatic logic [31:0] ADDI (int rd, int rs1, int imm);    return enc_i(imm, rs1, 3'b000, rd, OP_IMM);      endfunction
    function automatic logic [31:0] XORI (int rd, int rs1, int imm);    return enc_i(imm, rs1, 3'b100, rd, OP_IMM);      endfunction
    function automatic logic [31:0] SLLI (int rd, int rs1, int sh);     return enc_i(sh,  rs1, 3'b001, rd, OP_IMM);      endfunction

    function automatic logic [31:0] ADD  (int rd, int rs1, int rs2);    return enc_r(7'b0000000, rs2, rs1, 3'b000, rd, OP_OP); endfunction
    function automatic logic [31:0] SUB  (int rd, int rs1, int rs2);    return enc_r(7'b0100000, rs2, rs1, 3'b000, rd, OP_OP); endfunction
    function automatic logic [31:0] SLT  (int rd, int rs1, int rs2);    return enc_r(7'b0000000, rs2, rs1, 3'b010, rd, OP_OP); endfunction
    function automatic logic [31:0] SRA  (int rd, int rs1, int rs2);    return enc_r(7'b0100000, rs2, rs1, 3'b101, rd, OP_OP); endfunction

    function automatic logic [31:0] CSRRW(int rd, int csr, int rs1);    return enc_i(csr, rs1, 3'b001, rd, OP_SYSTEM);   endfunction
    function automatic logic [31:0] CSRRS(int rd, int csr, int rs1);    return enc_i(csr, rs1, 3'b010, rd, OP_SYSTEM);   endfunction
    function automatic logic [31:0] CSRR (int rd, int csr);             return CSRRS(rd, csr, 0);                        endfunction

    function automatic logic [31:0] NOP  ();                            return ADDI(0, 0, 0);                            endfunction
    function automatic logic [31:0] ECALL();                            return 32'h0000_0073;                            endfunction
    function automatic logic [31:0] MRET ();                            return 32'h3020_0073;                            endfunction

    localparam int CSR_MSTATUS = 12'h300;
    localparam int CSR_MIE     = 12'h304;
    localparam int CSR_MTVEC  = 12'h305;
    localparam int CSR_MEPC   = 12'h341;
    localparam int CSR_MCAUSE = 12'h342;

    // Reference words from the RISC-V spec / GNU as. Returns the number of
    // mismatches so the caller can stop before running anything.
    function automatic int check_word(logic [31:0] got, logic [31:0] want, string what);
        if (got === want) return 0;
        $display("ASM SELFTEST FAIL: %s = %08h, want %08h", what, got, want);
        return 1;
    endfunction

    function automatic int selftest();
        int bad = 0;
        bad += check_word(ADDI (1, 0, 5),        32'h0050_0093, "addi x1,x0,5");
        bad += check_word(ADD  (3, 1, 2),        32'h0020_81b3, "add x3,x1,x2");
        bad += check_word(SUB  (3, 1, 2),        32'h4020_81b3, "sub x3,x1,x2");
        bad += check_word(LW   (6, 10, 0),       32'h0005_2303, "lw x6,0(x10)");
        bad += check_word(SW   (6, 10, 4),       32'h0065_2223, "sw x6,4(x10)");
        bad += check_word(BEQ  (1, 1, 12),       32'h0010_8663, "beq x1,x1,+12");
        bad += check_word(BNE  (1, 2, -8),       32'hfe20_9ce3, "bne x1,x2,-8");
        bad += check_word(JAL  (1, 8),           32'h0080_00ef, "jal x1,+8");
        bad += check_word(JALR (0, 1, 0),        32'h0000_8067, "jalr x0,0(x1)");
        bad += check_word(LUI  (31, 32'h10),     32'h0001_0fb7, "lui x31,0x10");
        bad += check_word(CSRRW(0, 12'h305, 5),  32'h3052_9073, "csrw mtvec,x5");
        return bad;
    endfunction

endpackage
