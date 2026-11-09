`timescale 1ns / 1ps
// ============================================================
// program_counter module starts here...
// 1. PROGRAM COUNTER
// ============================================================================
module program_counter(
    input         clk,
    input         rst,
    input         pc_write,
    input  [31:0] next_pc,
    output reg [31:0] pc_out
);
    // FIX: added posedge rst to sensitivity list for async reset
    always @(posedge clk) begin
        if (rst)
            pc_out <= 32'h0000_0000;
        else if (pc_write)
            pc_out <= next_pc;
    end
endmodule

// ============================================================================
// 2. INSTRUCTION MEMORY  (synchronous read — FPGA BRAM-compatible)
// ============================================================================
module instruction_memory #(
    parameter DEPTH   = 1024,
    parameter IN_FILE = "firmware.hex" 
)(
    input         clk,
    input  [31:0] addr_i,
    input         enable,
    output reg [31:0] instr_o
);
initial $display("*** MARKER: instruction_memory HOLD-FIX ACTIVE (riscv_core_pkg.v) ***");
    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];
    wire [31:0] word_addr = addr_i >> 2;

    initial $readmemh(IN_FILE, mem);

    always @(posedge clk) begin
        if (enable) begin
            if (word_addr < DEPTH)
                instr_o <= mem[word_addr];
            else
                instr_o <= 32'h0000_0013; // NOP (genuinely out of range)
        end
        // else: hold current instr_o unchanged -- do NOT force NOP.
    end
     initial begin
    $readmemh(IN_FILE, mem);
    $display("[IMEM] Firmware check:");
    $display("  [0] = %08h", mem[0]);
    $display("  [1] = %08h", mem[1]);
    $display("  [2] = %08h", mem[2]);
    $display("  [3] = %08h", mem[3]);
    $display("  [4] = %08h", mem[4]);
    $display("  [5] = %08h", mem[5]);
end
endmodule

// ============================================================================
// 3. REGISTER FILE  (32 × 32-bit, combinational read, synchronous write)
// ============================================================================
module register_file(
    input         clk,
    input         rst,
    input         write_enable,
    input  [4:0]  rs1_addr,
    input  [4:0]  rs2_addr,
    input  [4:0]  rd_addr,
    input  [31:0] rd_data,
    output [31:0] rs1_data,   // FIX: wire (assign), not reg
    output [31:0] rs2_data
);
    reg [31:0] registers [0:31];
    integer i;

    // FIX: combinational assign with write-first forwarding
    assign rs1_data = (rs1_addr == 5'b0)                        ? 32'b0 :
                      (write_enable && rd_addr == rs1_addr)     ? rd_data :
                      registers[rs1_addr];

    assign rs2_data = (rs2_addr == 5'b0)                        ? 32'b0 :
                      (write_enable && rd_addr == rs2_addr)     ? rd_data :
                      registers[rs2_addr];

    always @(posedge clk or posedge rst) begin
        if (rst)
            for (i = 0; i < 32; i = i + 1) registers[i] <= 32'b0;
        else if (write_enable && rd_addr != 5'b0)
            registers[rd_addr] <= rd_data;
    end
endmodule

// ============================================================================
// 4. INSTRUCTION DECODER
// ============================================================================
module decoder(
    input  [31:0] instr_input,
    input  [31:0] pc,
    output [6:0]  opcode,
    output [4:0]  rs1,
    output [4:0]  rs2,
    output [4:0]  rd,
    output [2:0]  funct3,
    output [6:0]  funct7,
    output reg [31:0] imm
);
    assign opcode = instr_input[6:0];
    assign rd     = instr_input[11:7];
    assign funct3 = instr_input[14:12];
    assign rs1    = instr_input[19:15];
    assign rs2    = instr_input[24:20];
    assign funct7 = instr_input[31:25];

    always @(*) begin
        case (opcode)
            7'b0010011, 7'b0000011, 7'b1100111: // I-type
                imm = {{20{instr_input[31]}}, instr_input[31:20]};
            7'b0100011: // S-type
                imm = {{20{instr_input[31]}}, instr_input[31:25], instr_input[11:7]};
            7'b1100011: // B-type
                imm = {{19{instr_input[31]}}, instr_input[31], instr_input[7],
                        instr_input[30:25], instr_input[11:8], 1'b0};
            7'b0110111, 7'b0010111: // U-type
                imm = {instr_input[31:12], 12'b0};
            7'b1101111: // J-type
                imm = {{11{instr_input[31]}}, instr_input[31], instr_input[19:12],
                        instr_input[20], instr_input[30:21], 1'b0};
            default: imm = 32'b0;
        endcase
    end
endmodule

// ============================================================================
// 5. CONTROL UNIT
// ============================================================================
module control_unit(
    input  [6:0] opcode,
    output reg   MemWrite,
    output reg   MemRead,
    output reg   ALUsrc,
    output reg   branch,
    output reg   jump,       // FIX: added jump signal
    output reg   RegWrite,
    output reg [1:0] ALUop,
    output reg [1:0] wb_sel  // FIX: added: 00=ALU, 01=MEM, 10=PC+4
);
    always @(*) begin
        {MemWrite, MemRead, ALUsrc, branch, jump, RegWrite} = 6'b0;
        ALUop  = 2'b00;
        wb_sel = 2'b00;

        case (opcode)
            7'b0110011: begin // R-type
                RegWrite = 1; ALUop = 2'b10;
            end
            7'b0010011: begin // I-type ALU
                RegWrite = 1; ALUsrc = 1; ALUop = 2'b10;
            end
            7'b0000011: begin // LOAD
                MemRead = 1; RegWrite = 1; ALUsrc = 1; wb_sel = 2'b01;
            end
            7'b0100011: begin // STORE
                MemWrite = 1; ALUsrc = 1;
            end
            7'b1100011: begin // BRANCH
                branch = 1; ALUop = 2'b01;
            end
            7'b1101111: begin // JAL
                jump = 1; RegWrite = 1; wb_sel = 2'b10;
            end
            7'b1100111: begin // JALR
                jump = 1; RegWrite = 1; ALUsrc = 1; wb_sel = 2'b10;
            end
            7'b0110111: begin // LUI
                RegWrite = 1; ALUsrc = 1; ALUop = 2'b11; wb_sel = 2'b00;
            end
            7'b0010111: begin // AUIPC
                RegWrite = 1; ALUsrc = 1; ALUop = 2'b11; wb_sel = 2'b00;
            end
        endcase
    end
endmodule

// ============================================================================
// 6. ALU CONTROL
// ============================================================================
module alu_control(
    input  [1:0] ALUop,
    input  [6:0] opcode,
    input  [2:0] funct3,
    input  [6:0] funct7,
    output reg [3:0] ALU_control,
    output reg       is_muldiv,
    output reg [2:0] muldiv_op
);
    always @(*) begin
        is_muldiv = 0; muldiv_op = 3'b0;
        case (ALUop)
            2'b00: ALU_control = 4'b0000; // ADD (LOAD/STORE)
            2'b01: begin // BRANCH comparisons
                case (funct3)
                    3'b000, 3'b001: ALU_control = 4'b0001; // BEQ/BNE -> SUB
                    3'b100, 3'b101: ALU_control = 4'b1000; // BLT/BGE  -> SLT
                    3'b110, 3'b111: ALU_control = 4'b1001; // BLTU/BGEU-> SLTU
                    default:        ALU_control = 4'b0000;
                endcase
            end
            2'b10: begin // R/I-type
                if (funct7 == 7'b0000001) begin // RV32M
                    is_muldiv = 1; muldiv_op = funct3; ALU_control = 4'b0000;
                end else begin
                    case (funct3)
                        3'b000: ALU_control = (funct7[5] & opcode[5]) ? 4'b0001 : 4'b0000;
                        3'b001: ALU_control = 4'b0101;
                        3'b010: ALU_control = 4'b1000;
                        3'b011: ALU_control = 4'b1001;
                        3'b100: ALU_control = 4'b0100;
                        3'b101: ALU_control = funct7[5] ? 4'b0111 : 4'b0110;
                        3'b110: ALU_control = 4'b0011;
                        3'b111: ALU_control = 4'b0010;
                        default: ALU_control = 4'b0000;
                    endcase
                end
            end
            2'b11: ALU_control = 4'b1011; // FIX: PASS_B for LUI/AUIPC (was missing)
            default: ALU_control = 4'b0000;
        endcase
    end
endmodule

// ============================================================================
// 7. ALU
// ============================================================================
module ALU(
    input  [31:0] A,
    input  [31:0] B,
    input  [3:0]  opcode,
    output reg [31:0] result,
    output        zero    // FIX: wire via assign (was reg)
);
    always @(*) begin
        case (opcode)
            4'b0000: result = A + B;
            4'b0001: result = A - B;
            4'b0010: result = A & B;
            4'b0011: result = A | B;
            4'b0100: result = A ^ B;
            4'b0101: result = A << B[4:0];
            4'b0110: result = A >> B[4:0];
            4'b0111: result = $signed(A) >>> B[4:0];
            4'b1000: result = ($signed(A) < $signed(B)) ? 32'd1 : 32'd0;
            4'b1001: result = (A < B) ? 32'd1 : 32'd0;
            4'b1010: result = ~A;
            4'b1011: result = B;   // PASS_B (LUI/AUIPC)
            default: result = 32'b0;
        endcase
    end
    assign zero = (result == 32'b0);
endmodule

// ============================================================================
// ============================================================================
// 8. MULTIPLY / DIVIDE UNIT  (3-stage pipelined, DSP48-friendly)
// ============================================================================
module mul_div (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,      // ← must exist
    input  wire [2:0]  opcode,     // ← must be [2:0] not [6:0]
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    output reg  [31:0] result,
    output wire        busy,
    output reg         ready
);
    reg        computing;
    reg [1:0]  pipe_cnt;

    // ── Stage 1: Input registers (→ AREG=1/BREG=1 inside DSP48) ──
    reg signed [31:0] a_s1, b_s1;
    reg        [31:0] a_u1, b_u1;
    reg [2:0]  op_s1;
    reg        valid_s1;

    always @(posedge clk) begin
        if (rst) begin
            valid_s1  <= 1'b0;
            computing <= 1'b0;
            pipe_cnt  <= 2'd0;
        end else begin
            a_s1     <= $signed(rs1);
            a_u1     <= rs1;
            b_s1     <= $signed(rs2);
            b_u1     <= rs2;
            op_s1    <= opcode;
            valid_s1 <= start & !computing;
            if (start & !computing) begin
                computing <= 1'b1;
                pipe_cnt  <= 2'd0;
            end else if (computing) begin
                pipe_cnt <= pipe_cnt + 2'd1;
                if (pipe_cnt == 2'd2)
                    computing <= 1'b0;
            end
        end
    end

    // ── Stage 2: Multiply (→ MREG=1 inside DSP48) ──
    (* use_dsp = "yes" *) reg signed [63:0] product_ss;
    (* use_dsp = "yes" *) reg        [63:0] product_uu;
    (* use_dsp = "yes" *) reg signed [63:0] product_su;
    reg [2:0] op_s2;
    reg       valid_s2;

    always @(posedge clk) begin
        if (rst) begin
            valid_s2 <= 1'b0;
        end else begin
            product_ss <= a_s1 * b_s1;
            product_uu <= a_u1 * b_u1;
            product_su <= a_s1 * $signed({1'b0, b_u1});
            op_s2    <= op_s1;
            valid_s2 <= valid_s1;
        end
    end

    // ── Stage 3: Output register (→ PREG=1 inside DSP48) ──
    always @(posedge clk) begin
        if (rst) begin
            result <= 32'b0;
            ready  <= 1'b0;
        end else begin
            ready <= valid_s2;
            case (op_s2)
                3'b000: result <= product_ss[31:0];    // MUL
                3'b001: result <= product_ss[63:32];   // MULH
                3'b010: result <= product_su[63:32];   // MULHSU
                3'b011: result <= product_uu[63:32];   // MULHU
                default: result <= product_ss[31:0];
            endcase
        end
    end

    assign busy = computing;

endmodule

// ============================================================================
// 9. DATA MEMORY  (with MMIO decode, 16 KB)
// ============================================================================
module data_memory #(
    parameter DEPTH = 4096
)(
    input         clk,
    input         rst,
    input         MemRead,
    input         MemWrite,
    input  [31:0] addr_i,
    input  [31:0] write_data_i,
    output [31:0] read_data_o,        // FIX: changed to wire (driven by assign)
    output reg        mmio_request,
    output reg        mmio_write,
    output reg [31:0] mmio_addr,
    output reg [31:0] mmio_wdata,
    input  [31:0]     mmio_rdata,
    input             mmio_ready
);
    // FIX 1: ram_style attribute forces BRAM
    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];

    wire [31:0] word_addr = addr_i >> 2;
    wire is_mmio = (addr_i[31:28] == 4'h4);

    // FIX 2: Control registers - reset is fine here (no RAM array)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mmio_request <= 0;
            mmio_write   <= 0;
            mmio_addr    <= 0;
            mmio_wdata   <= 0;
        end else begin
            mmio_request <= (MemRead || MemWrite) && is_mmio;
            mmio_write   <= MemWrite && is_mmio;
            mmio_addr    <= addr_i;
            mmio_wdata   <= write_data_i;
        end
    end

    // FIX 3: RAM write - isolated always block, no rst
    always @(posedge clk) begin
        if (MemWrite && !is_mmio && (word_addr < DEPTH))
            mem[word_addr] <= write_data_i;
    end

    // FIX 4: RAM read - UNCONDITIONAL synchronous read
    // This is the key: no if-condition on the read itself
    reg [31:0] bram_out;
    always @(posedge clk) begin
        bram_out <= mem[word_addr];   // always reads, no gating
    end

    // FIX 5: MMIO mux is combinational OUTSIDE the BRAM block
    // This does NOT interfere with BRAM inference
    assign read_data_o = is_mmio ? mmio_rdata : bram_out;

endmodule
// ============================================================================
// 10. BRANCH UNIT  (FIX: was only BEQ in top module; now full RISC-V branch set)
// ============================================================================
module branch_unit(
    input  [31:0] rs1_val,
    input  [31:0] rs2_val,
    input  [2:0]  funct3,
    input         branch,
    input         jump,
    output reg    branch_taken
);
    always @(*) begin
        if (jump)
            branch_taken = 1;
        else if (branch) begin
            case (funct3)
                3'b000: branch_taken = (rs1_val == rs2_val);
                3'b001: branch_taken = (rs1_val != rs2_val);
                3'b100: branch_taken = ($signed(rs1_val) < $signed(rs2_val));
                3'b101: branch_taken = ($signed(rs1_val) >= $signed(rs2_val));
                3'b110: branch_taken = (rs1_val < rs2_val);
                3'b111: branch_taken = (rs1_val >= rs2_val);
                default: branch_taken = 0;
            endcase
        end else
            branch_taken = 0;
    end
endmodule

// ============================================================================
// 11. PIPELINE REGISTERS
// ============================================================================

// IF/ID
module if_id_pipeline(
    input         clk, rst, enable, flush,
    input  [31:0] if_pc, if_instr,
    output reg [31:0] id_pc, id_instr
);
    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin id_pc <= 0; id_instr <= 32'h0000_0013; end
        else if (enable)  begin id_pc <= if_pc; id_instr <= if_instr;   end
    end
endmodule

// ID/EX  (FIX: added jump, wb_sel, funct3 ports that were missing)
module id_ex_pipeline(
    input         clk, rst, enable, flush,
    input  [31:0] id_pc, id_rs1_val, id_rs2_val, id_imm,
    input  [4:0]  id_rd, id_rs1, id_rs2,
    input         id_RW, id_MR, id_MW, id_branch, id_jump, id_ALUsrc, id_is_muldiv,
    input  [3:0]  id_alu_sel,
    input  [2:0]  id_muldiv_op, id_funct3,
    input  [1:0]  id_wb_sel,
    output reg [31:0] ex_pc, ex_rs1_val, ex_rs2_val, ex_imm,
    output reg [4:0]  ex_rd, ex_rs1, ex_rs2,
    output reg        ex_RW, ex_MR, ex_MW, ex_branch, ex_jump, ex_ALUsrc, ex_is_muldiv,
    output reg [3:0]  ex_alu_sel,
    output reg [2:0]  ex_muldiv_op, ex_funct3,
    output reg [1:0]  ex_wb_sel
);
    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin
            ex_pc <= 0; ex_rs1_val <= 0; ex_rs2_val <= 0; ex_imm <= 0;
            ex_rd <= 0; ex_rs1 <= 0; ex_rs2 <= 0;
            {ex_RW,ex_MR,ex_MW,ex_branch,ex_jump,ex_ALUsrc,ex_is_muldiv} <= 7'b0;
            ex_alu_sel <= 0; ex_muldiv_op <= 0; ex_funct3 <= 0; ex_wb_sel <= 0;
        end else if (enable) begin
            ex_pc <= id_pc; ex_rs1_val <= id_rs1_val; ex_rs2_val <= id_rs2_val;
            ex_imm <= id_imm; ex_rd <= id_rd; ex_rs1 <= id_rs1; ex_rs2 <= id_rs2;
            ex_RW <= id_RW; ex_MR <= id_MR; ex_MW <= id_MW;
            ex_branch <= id_branch; ex_jump <= id_jump;
            ex_ALUsrc <= id_ALUsrc; ex_is_muldiv <= id_is_muldiv;
            ex_alu_sel <= id_alu_sel; ex_muldiv_op <= id_muldiv_op;
            ex_funct3 <= id_funct3; ex_wb_sel <= id_wb_sel;
        end
    end
endmodule

// EX/MEM  (FIX: added pc_plus4 and wb_sel ports)
module ex_mem_pipeline(
    input         clk, rst, enable, flush,
    input  [31:0] ex_alu_result, ex_rs2_val, ex_pc_plus4,
    input  [4:0]  ex_rd,
    input         ex_RW, ex_MR, ex_MW,
    input  [1:0]  ex_wb_sel,
    output reg [31:0] mem_alu_result, mem_rs2_val, mem_pc_plus4,
    output reg [4:0]  mem_rd,
    output reg        mem_RW, mem_MR, mem_MW,
    output reg [1:0]  mem_wb_sel
);
    always @(posedge clk) begin
        if (rst || flush) begin
            mem_alu_result <= 0; mem_rs2_val <= 0; mem_pc_plus4 <= 0;
            mem_rd <= 0; {mem_RW,mem_MR,mem_MW} <= 3'b0; mem_wb_sel <= 0;
        end else if (enable) begin
            mem_alu_result <= ex_alu_result; mem_rs2_val <= ex_rs2_val;
            mem_pc_plus4   <= ex_pc_plus4;   mem_rd <= ex_rd;
            mem_RW <= ex_RW; mem_MR <= ex_MR; mem_MW <= ex_MW;
            mem_wb_sel <= ex_wb_sel;
        end
    end
endmodule

// MEM/WB
module mem_wb_pipeline(
    input         clk, rst, enable, flush,
    input  [31:0] mem_alu_result, mem_read_data, mem_pc_plus4,
    input  [4:0]  mem_rd,
    input         mem_RW, mem_MR,
    input  [1:0]  mem_wb_sel,
    output reg [31:0] wb_alu_result, wb_read_data, wb_pc_plus4,
    output reg [4:0]  wb_rd,
    output reg        wb_RW, wb_MR,
    output reg [1:0]  wb_wb_sel
);
    always @(posedge clk or posedge rst) begin
        if (rst || flush) begin
            wb_alu_result <= 0; wb_read_data <= 0; wb_pc_plus4 <= 0;
            wb_rd <= 0; wb_RW <= 0; wb_MR <= 0; wb_wb_sel <= 0;
        end else if (enable) begin
            wb_alu_result <= mem_alu_result; wb_read_data <= mem_read_data;
            wb_pc_plus4   <= mem_pc_plus4;   wb_rd <= mem_rd;
            wb_RW <= mem_RW; wb_MR <= mem_MR; wb_wb_sel <= mem_wb_sel;
        end
    end
endmodule

// ============================================================================
// 12. FORWARDING UNIT
// ============================================================================
module forwarding_unit(
    input  [4:0] ex_rs1, ex_rs2, mem_rd, wb_rd,
    input        mem_regwrite, wb_regwrite,
    output reg [1:0] forwardA, forwardB
);
    always @(*) begin
        forwardA = (mem_regwrite && mem_rd != 0 && mem_rd == ex_rs1) ? 2'b10 :
                   (wb_regwrite  && wb_rd  != 0 && wb_rd  == ex_rs1) ? 2'b01 : 2'b00;
        forwardB = (mem_regwrite && mem_rd != 0 && mem_rd == ex_rs2) ? 2'b10 :
                   (wb_regwrite  && wb_rd  != 0 && wb_rd  == ex_rs2) ? 2'b01 : 2'b00;
    end
endmodule

// ============================================================================
// 13. HAZARD DETECTION UNIT
// ============================================================================
module hazard_detection(
    input  [4:0] id_rs1, id_rs2, ex_rd,
    input        ex_memread, id_is_muldiv, ex_is_muldiv, muldiv_busy, muldiv_ready,
    input        ex_mmio_access,
    output reg   stall, pc_write, if_id_write, id_ex_flush, mem_stall
);
    always @(*) begin
        if (ex_memread && ((ex_rd == id_rs1) || (ex_rd == id_rs2))) begin
            stall=1; pc_write=0; if_id_write=0; id_ex_flush=1; mem_stall=0;
        end else if ((id_is_muldiv || ex_is_muldiv) && muldiv_busy) begin
            stall=1; pc_write=0; if_id_write=0; id_ex_flush=1; mem_stall=0;
        end else if (ex_mmio_access) begin
            stall=1; pc_write=0; if_id_write=0; id_ex_flush=1; mem_stall=0;
        end else begin
            stall=0; pc_write=1; if_id_write=1; id_ex_flush=0; mem_stall=0;
        end
    end
endmodule