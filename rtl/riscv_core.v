`timescale 1ns / 1ps

module riscv_core(
    input  clk,
    input  rst,
    // MMIO bus out to SoC peripherals
    output        mmio_request,
    output        mmio_write_out,
    output [31:0] mmio_addr_out,
    output [31:0] mmio_wdata_out,
    input  [31:0] mmio_rdata_in,
    input         mmio_ready_in
);
initial $display("*** MARKER: riscv_core.V EDITED VERSION LOADED -- ex_ALUsrc branch fix + IMEM hold fix ***");
// Forward declarations - MMIO stall gated signals
wire is_mem_mmio;
wire mmio_read_stall;
wire pc_write_gated;
wire if_id_write_gated;

    // ---- IF stage ----
    wire [31:0] pc, next_pc, instr;
    wire pc_write, if_id_write, if_id_flush, id_ex_flush;
reg  [31:0] pc_fetch;   // PC value that produced `instr`, delayed to match IMEM latency
reg branch_taken_d1;
 wire branch_taken;
always @(posedge clk or posedge rst) begin
    if (rst) branch_taken_d1 <= 1'b0;
    else     branch_taken_d1 <= branch_taken;
end

always @(posedge clk) begin
    if (if_id_write_gated)
        pc_fetch <= pc;
    // else: hold pc_fetch unchanged, staying paired with the held
    // `instr` value from the (now correctly gated) instruction_memory --
    // without this, pc_fetch can advance one word ahead of `instr`
    // during the exact cycle a freeze first engages, corrupting
    // id_pc/ex_pc for whatever instruction is paired with the held
    // instr on the next capture.
end

    program_counter PC (
        .clk(clk), .rst(rst), .pc_write(pc_write_gated),
        .next_pc(next_pc), .pc_out(pc)
    );

    instruction_memory #(.DEPTH(1024), .IN_FILE("firmware.hex")) IMEM (
        .clk(clk), .addr_i(pc), .enable(if_id_write_gated), .instr_o(instr)
    );

    // ---- IF/ID ----
    wire [31:0] id_pc, id_instr;
    if_id_pipeline IF_ID (
        .clk(clk), .rst(rst), .enable(if_id_write_gated), .flush(if_id_flush),
        .if_pc(pc_fetch), .if_instr(instr), .id_pc(id_pc), .id_instr(id_instr)
    );

    // ---- ID stage ----
    wire [6:0]  opcode; wire [4:0] rs1, rs2, rd;
    wire [2:0]  funct3; wire [6:0] funct7; wire [31:0] imm;
    decoder DEC (
        .instr_input(id_instr), .pc(id_pc),
        .opcode(opcode), .rs1(rs1), .rs2(rs2), .rd(rd),
        .funct3(funct3), .funct7(funct7), .imm(imm)
    );

    wire MemWrite_c, MemRead_c, ALUsrc_c, branch_c, jump_c, RegWrite_c;
    wire [1:0] ALUop_c, wb_sel_c;
    control_unit CTRL (
        .opcode(opcode), .MemWrite(MemWrite_c), .MemRead(MemRead_c),
        .ALUsrc(ALUsrc_c), .branch(branch_c), .jump(jump_c),
        .RegWrite(RegWrite_c), .ALUop(ALUop_c), .wb_sel(wb_sel_c)
    );

    wire [3:0] alu_ctrl_c; wire id_is_muldiv; wire [2:0] id_muldiv_op;
    alu_control ALUCTRL (
        .ALUop(ALUop_c), .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .ALU_control(alu_ctrl_c), .is_muldiv(id_is_muldiv), .muldiv_op(id_muldiv_op)
    );

    wire [31:0] rs1_data, rs2_data, wb_data;
    wire        wb_RW; wire [4:0] wb_rd;
    register_file REGFILE (
        .clk(clk), .rst(rst), .write_enable(wb_RW),
        .rs1_addr(rs1), .rs2_addr(rs2), .rd_addr(wb_rd), .rd_data(wb_data),
        .rs1_data(rs1_data), .rs2_data(rs2_data)
    );

    // ---- ID/EX ----
    wire [31:0] ex_pc, ex_rs1_val, ex_rs2_val, ex_imm;
    wire [4:0]  ex_rd, ex_rs1, ex_rs2;
    wire        ex_RW, ex_MR, ex_MW, ex_branch, ex_jump, ex_ALUsrc, ex_is_muldiv;
    wire [3:0]  ex_alu_sel; wire [2:0] ex_muldiv_op, ex_funct3; wire [1:0] ex_wb_sel;
   

    id_ex_pipeline ID_EX (
        .clk(clk), .rst(rst), .enable(!stall_w && !mmio_read_stall), .flush(id_ex_flush||branch_taken),
        .id_pc(id_pc), .id_rs1_val(rs1_data), .id_rs2_val(rs2_data),
        .id_imm(imm), .id_rd(rd), .id_rs1(rs1), .id_rs2(rs2),
        .id_RW(RegWrite_c), .id_MR(MemRead_c), .id_MW(MemWrite_c),
        .id_branch(branch_c), .id_jump(jump_c), .id_ALUsrc(ALUsrc_c),
        .id_is_muldiv(id_is_muldiv), .id_alu_sel(alu_ctrl_c),
        .id_muldiv_op(id_muldiv_op), .id_funct3(funct3), .id_wb_sel(wb_sel_c),
        .ex_pc(ex_pc), .ex_rs1_val(ex_rs1_val), .ex_rs2_val(ex_rs2_val),
        .ex_imm(ex_imm), .ex_rd(ex_rd), .ex_rs1(ex_rs1), .ex_rs2(ex_rs2),
        .ex_RW(ex_RW), .ex_MR(ex_MR), .ex_MW(ex_MW),
        .ex_branch(ex_branch), .ex_jump(ex_jump), .ex_ALUsrc(ex_ALUsrc),
        .ex_is_muldiv(ex_is_muldiv), .ex_alu_sel(ex_alu_sel),
        .ex_muldiv_op(ex_muldiv_op), .ex_funct3(ex_funct3), .ex_wb_sel(ex_wb_sel)
    );

    // ---- EX stage ----
    wire [1:0]  forwardA, forwardB;
    wire [31:0] mem_alu_result;
    wire        mem_RW; wire [4:0] mem_rd;

    forwarding_unit FWD (
        .ex_rs1(ex_rs1), .ex_rs2(ex_rs2), .mem_rd(mem_rd), .wb_rd(wb_rd),
        .mem_regwrite(mem_RW), .wb_regwrite(wb_RW),
        .forwardA(forwardA), .forwardB(forwardB)
    );

    // FIX: MEM-stage forwarding must NOT use mem_alu_result when the
    // MEM-stage instruction is a load (mem_MR) -- mem_alu_result is the
    // load's COMPUTED ADDRESS, not the data it read. For an ordinary
    // 1-cycle load this bug was invisible: hazard_detection's single-cycle
    // load-use bubble is timed so a load-dependent instruction always
    // reaches EX exactly when the load has ALREADY reached WB, so only
    // WB-forwarding (which correctly uses wb_data) was ever exercised.
    // But an MMIO load can take many EXTRA cycles (mmio_read_stall), during
    // which a dependent instruction sits frozen in EX while the load is
    // still frozen in MEM (not yet WB) -- and MEM-forwarding incorrectly
    // fires, handing it the load's ADDRESS instead of the data it read.
    // Observed causing e.g. `lw a4,0(a5); andi a4,a4,2; beq a4,zero,LOOP`
    // (a status-register poll) to silently use the MMIO address bits
    // instead of the loaded status value, making the retry-branch behave
    // unpredictably and letting a receive loop race past real hardware
    // events it should have blocked on.
    wire mem_MR;
    wire [31:0]mem_read_data;
    wire [31:0] mem_fwd_val = mem_MR ? mem_read_data : mem_alu_result;
  

    wire [31:0] alu_in1 =
        (forwardA == 2'b10) ? mem_fwd_val :
        (forwardA == 2'b01) ? wb_data : ex_rs1_val;

    wire [31:0] alu_in2_raw =
        (forwardB == 2'b10) ? mem_fwd_val :
        (forwardB == 2'b01) ? wb_data : ex_rs2_val;

    wire [31:0] alu_in2 = ex_ALUsrc ? ex_imm : alu_in2_raw;

    wire [31:0] alu_result; wire alu_zero;
    ALU ALU_inst (
        .A(alu_in1), .B(alu_in2), .opcode(ex_alu_sel),
        .result(alu_result), .zero(alu_zero)
    );

    wire [31:0] muldiv_result; wire muldiv_busy, muldiv_ready;
   mul_div MULDIV (
    .clk    (clk),
    .rst    (rst),
    .start  (ex_is_muldiv),   // ← must say 'start'
    .opcode (ex_muldiv_op),   // ← [2:0] wire
    .rs1    (alu_in1),
    .rs2    (alu_in2_raw),
    .busy   (muldiv_busy),
    .ready  (muldiv_ready),
    .result (muldiv_result)
);

    wire [31:0] ex_result =
        (ex_is_muldiv && muldiv_ready) ? muldiv_result :
        (!ex_is_muldiv)                ? alu_result : 32'b0;

    // FIX: use branch_unit instead of bare BEQ
    
    branch_unit BU (
        .rs1_val(alu_in1), .rs2_val(alu_in2_raw),
        .funct3(ex_funct3), .branch(ex_branch), .jump(ex_jump),
        .branch_taken(branch_taken)
    );

    
    wire [31:0] branch_target;
    // For JAL: PC + imm; for JALR: (rs1 + imm) & ~1
    // FIX: ex_alu_sel aliases to the same value (4'b0000) for both JAL
    // and JALR since control_unit never sets a distinguishing ALUop for
    // either -- use ex_ALUsrc instead (set to 1 only for JALR).
    assign branch_target = ex_jump && !ex_branch ?
                           (ex_ALUsrc ? (alu_in1 + ex_imm) & ~32'b1 :
                            ex_pc + ex_imm) :
                           ex_pc + ex_imm;

    wire [31:0] ex_pc_plus4 = ex_pc + 4;

    // ---- EX/MEM ----
    wire [31:0] mem_rs2_val, mem_pc_plus4;
    wire         mem_MW; wire [1:0] mem_wb_sel;

   ex_mem_pipeline EX_MEM (
    .clk(clk), .rst(rst), .enable(!mmio_read_stall), .flush(1'b0),
        .ex_alu_result(ex_result), .ex_rs2_val(alu_in2_raw),
        .ex_pc_plus4(ex_pc_plus4), .ex_rd(ex_rd),
        .ex_RW(ex_RW), .ex_MR(ex_MR), .ex_MW(ex_MW), .ex_wb_sel(ex_wb_sel),
        .mem_alu_result(mem_alu_result), .mem_rs2_val(mem_rs2_val),
        .mem_pc_plus4(mem_pc_plus4), .mem_rd(mem_rd),
        .mem_RW(mem_RW), .mem_MR(mem_MR), .mem_MW(mem_MW), .mem_wb_sel(mem_wb_sel)
    );

    // ---- MEM stage ----
    
    wire dmem_mmio_req, dmem_mmio_wr;
    wire [31:0] dmem_mmio_addr, dmem_mmio_wdata;

    data_memory #(.DEPTH(4096)) DMEM (
        .clk(clk), .rst(rst), .MemRead(mem_MR), .MemWrite(mem_MW),
        .addr_i(mem_alu_result), .write_data_i(mem_rs2_val),
        .read_data_o(mem_read_data),
        .mmio_request(mmio_request), .mmio_write(mmio_write_out),
        .mmio_addr(mmio_addr_out), .mmio_wdata(mmio_wdata_out),
        .mmio_rdata(mmio_rdata_in), .mmio_ready(mmio_ready_in)
    );

    // ---- MEM/WB ----
    wire [31:0] wb_alu_result, wb_read_data, wb_pc_plus4;
    wire        wb_MR; wire [1:0] wb_wb_sel;

    mem_wb_pipeline MEM_WB (
        .clk(clk), .rst(rst), .enable(!mmio_read_stall), .flush(1'b0),
        .mem_alu_result(mem_alu_result), .mem_read_data(mem_read_data),
        .mem_pc_plus4(mem_pc_plus4), .mem_rd(mem_rd),
        .mem_RW(mem_RW), .mem_MR(mem_MR), .mem_wb_sel(mem_wb_sel),
        .wb_alu_result(wb_alu_result), .wb_read_data(wb_read_data),
        .wb_pc_plus4(wb_pc_plus4), .wb_rd(wb_rd),
        .wb_RW(wb_RW), .wb_MR(wb_MR), .wb_wb_sel(wb_wb_sel)
    );

    // ---- WB stage (FIX: 3-way mux for ALU/MEM/PC+4) ----
    assign wb_data = (wb_wb_sel == 2'b01) ? wb_read_data :
                     (wb_wb_sel == 2'b10) ? wb_pc_plus4  : wb_alu_result;

    // ---- Next PC ----
    assign next_pc = branch_taken ? branch_target : (pc + 4);

    // ---- Hazard detection ----
    wire  mem_stall_w;
  wire ex_mmio_access = (ex_MR || ex_MW) && (alu_result[31:28] == 4'h4);
hazard_detection HZD (
    .id_rs1(rs1), .id_rs2(rs2), .ex_rd(ex_rd),
    .ex_memread(ex_MR), .id_is_muldiv(id_is_muldiv),
    .ex_is_muldiv(ex_is_muldiv), .muldiv_busy(muldiv_busy),
    .muldiv_ready(muldiv_ready), .ex_mmio_access(ex_mmio_access),
    .stall(stall_w), .pc_write(pc_write), .if_id_write(if_id_write),
    .id_ex_flush(id_ex_flush), .mem_stall(mem_stall_w)
);

    // riscv_core.V
assign if_id_flush = (branch_taken | branch_taken_d1);
    // ---- MMIO Read Stall ----
// Freeze entire pipeline when MEM stage has a pending MMIO load
// FIX (superseded): an earlier attempt extended this to (mem_MR || mem_MW)
// to close a suspected write-then-read staleness gap. That introduced a
// NEW, worse bug: hazard_detection only ever inserts a bubble for
// ex_memread (loads), never for a pending write, so instructions
// immediately following a stalled MMIO write (e.g. `sw a4,0(a2); addi
// a2,a2,4; bne a2,a1,LOOP`) could resolve using stale pre-write operands
// before the store even reached MEM stage. The original staleness concern
// this was meant to fix is better addressed by mmio_controller's
// settle-cycle guard (mmio_req_first_cycle), which doesn't require
// touching pipeline stall timing at all. Reverted to mem_MR only.

assign is_mem_mmio     = (mem_alu_result[31:28] == 4'h4);

// mem_alu_result_prev tracks whether THIS cycle is the first time a
// new instruction's address is visible in MEM stage -- forcing one
// guaranteed stall cycle then, so the core never trusts a possibly
// stale mmio_ready_in left over from the immediately-preceding MMIO
// transaction before mmio_controller's own address-change detection
// (based on data_memory's one-cycle-delayed registered mmio_addr) has
// had a chance to catch up.
reg [31:0] mem_alu_result_prev;
always @(posedge clk or posedge rst) begin
    if (rst) mem_alu_result_prev <= 32'b0;
    else     mem_alu_result_prev <= mem_alu_result;
end
wire core_new_mmio_txn = (mem_alu_result != mem_alu_result_prev);
assign mmio_read_stall = (mem_MR || mem_MW) && is_mem_mmio && (core_new_mmio_txn || !mmio_ready_in);

// Override PC write to include MMIO stall
// (pc_write already declared from hazard unit)
assign pc_write_gated   = pc_write   && !mmio_read_stall;
assign if_id_write_gated = if_id_write && !mmio_read_stall;
endmodule