`timescale 1ns / 1ps
module dct_accelerator #(
    parameter BRAM_DEPTH = 4096
)(
    input         clk, rst,
    input         req, we,
    input  [7:0]  addr,
    input  [31:0] wdata,
    output reg [31:0] rdata,
    output     ready,
    // Shared BRAM port
    output reg [31:0] bram_addr,
    output reg [31:0] bram_wdata,
    output reg        bram_we,
    input  [31:0]     bram_rdata,
    output reg        bram_req
);
    // Control registers
    reg [31:0] ctrl_reg, input_addr_reg, output_addr_reg;
    // Row-stride registers (in words) let this block-transform engine be
    // pointed at an 8x8 sub-block sitting inside a LARGER image, instead of
    // only ever seeing a standalone contiguous 64-byte block. Defaults
    // reproduce the original standalone-block behaviour exactly:
    //   in_row_stride  = 2  (8 px/row  / 4 px-per-word = 2 words/row)
    //   out_row_stride = 4  (8 coef/row / 2 coef-per-word = 4 words/row)
    // frame_controller overrides these (to 8 and 16) when assembling a
    // full 32x32 frame out of a 4x4 grid of blocks.
    reg [31:0] in_row_stride_reg, out_row_stride_reg;
    reg        busy, done;

    // 8x8 pixel block buffer (8-bit pixels packed 4-per-word)
    reg [7:0]  blk_in  [0:63];   // input pixels
    reg signed [15:0] blk_out[0:63];  // column-pass result (separate buffer: the column pass
                                      // must not overwrite blk_dct while later outputs still read it)
    reg signed [15:0] blk_dct[0:63];  // DCT coefficients (Q8.8)
    reg [5:0]  pix_cnt;           // 0..63
    reg [5:0]  coef_cnt;

    // Fixed-point DCT basis vectors (cos((2n+1)*k*pi/16) * 128, k=0..7, n=0..7)
    // Stored as 8-bit signed values
    reg signed [8:0] cos_table [0:63];
    integer ii, jj;
    initial begin
        for (ii=0; ii<8; ii=ii+1)
            for (jj=0; jj<8; jj=jj+1)
                cos_table[ii*8+jj] = $rtoi($cos((2.0*jj+1)*ii*3.14159265/16.0) * 128.0);
    end

    localparam ST_IDLE=0, ST_LOAD=1, ST_DCTR=2, ST_DCTC=3, ST_STORE=4;
    reg [2:0] state;
    reg [2:0] r, c, k;  // FIX: was reg[5:0] -- {r,c} concatenation must produce
                        // a clean 6-bit index (r*8+c) into the 64-entry
                        // blk_in/blk_dct/cos_table arrays. With 6-bit regs,
                        // {r,c} produced r*64+c instead, which is out of
                        // range for any r>=1, reading back as X and silently
                        // corrupting every row of the DCT computation past
                        // the first.
    reg signed [23:0] acc;
    reg [1:0]        ph;      // 0 = fetch operands into a_q/b_q, 1 = multiply-accumulate
    reg signed [15:0] a_q;     // registered data operand (pixel or row-pass coefficient)
    reg signed [8:0]  b_q;     // registered cosine operand
    reg [31:0] load_addr, store_addr;
    reg [1:0]  word_off;
    reg ready_r;
    reg req_prev;
    
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ready_r <= 0;req_prev<=0;state<=ST_IDLE; busy<=0; done<=0; pix_cnt<=0; bram_req<=0; bram_we<=0;
            ctrl_reg<=0; input_addr_reg<=0; output_addr_reg<=0;
            in_row_stride_reg<=32'd2; out_row_stride_reg<=32'd4; ph<=0;
        end else begin
            req_prev <= req;ready_r <= req | req_prev;bram_req<=0; bram_we<=0;

            // Register interface
            if (req) begin
               
                if (we) case(addr[7:0])
                    8'h00: ctrl_reg       <= wdata;
                    8'h08: input_addr_reg <= wdata;
                    8'h0C: output_addr_reg<= wdata;
                    8'h14: in_row_stride_reg  <= wdata;
                    8'h18: out_row_stride_reg <= wdata;
                endcase
                else case(addr[7:0])
                    8'h00: rdata <= ctrl_reg;
                    8'h04: rdata <= {31'b0, busy};
                    8'h08: rdata <= input_addr_reg;
                    8'h0C: rdata <= output_addr_reg;
                    8'h10: rdata <= {blk_dct[0][15:0], blk_dct[1][15:0]};
                    8'h14: rdata <= in_row_stride_reg;
                    8'h18: rdata <= out_row_stride_reg;
                    default: rdata<=0;
                endcase
            end

            case (state)
                ST_IDLE: begin
                    done<=0;
                    if (ctrl_reg[0] && !busy) begin
                        busy<=1; pix_cnt<=0; r<=0; c<=0; k<=0;
                        load_addr <= input_addr_reg;
                        state<=ST_LOAD;
                        ctrl_reg[0]<=0;
                    end
                end

                // Load 64 pixels (16 words of 4 bytes each, but treat as byte pixels)
                ST_LOAD: begin
                    bram_req  <= 1;
                    // word addr = load_addr + row*in_row_stride + word_in_row(0/1)
                    // (row = pix_cnt[5:3], word_in_row = pix_cnt[2]; matches the
                    // original pix_cnt[5:2] exactly when in_row_stride==2)
                    bram_addr <= load_addr + ({26'b0, pix_cnt[5:3]} * in_row_stride_reg)
                                           + {31'b0, pix_cnt[2]};
                    bram_we   <= 0;
                    // Unpack 4 pixels per word on clock after bram read
                    if (pix_cnt[1:0]==2'b11) begin
                        blk_in[{pix_cnt[5:2],2'b00}] <= bram_rdata[31:24];
                        blk_in[{pix_cnt[5:2],2'b01}] <= bram_rdata[23:16];
                        blk_in[{pix_cnt[5:2],2'b10}] <= bram_rdata[15:8];
                        blk_in[{pix_cnt[5:2],2'b11}] <= bram_rdata[7:0];
                    end
                    pix_cnt <= pix_cnt + 1;
                    if (pix_cnt == 63) begin
                        r<=0; c<=0; k<=0; state<=ST_DCTR;
                    end
                end

                // Row DCT pass
                ST_DCTR: begin
                    if (ph == 2'd0) begin
                        // sub-phase 0: register the operands (64:1 mux + cos ROM only)
                        a_q <= $signed({8'b0, blk_in[{r,k}]}) - 16'sd128;
                        b_q <= cos_table[{c,k}];
                        ph  <= 2'd1;
                    end else if (ph == 2'd2) begin
                        // sub-phase 2: acc now holds the complete dot product
                        blk_dct[{r,c}] <= acc[22:7];  // Q8.8
                        ph <= 0;
                        if (c==7) begin
                            c<=0;
                            if (r==7) begin r<=0; c<=0; k<=0; state<=ST_DCTC; end
                            else r<=r+1;
                        end else c<=c+1;
                    end else begin
                    ph <= (k==7) ? 2'd2 : 2'd0;
                    if (k==0)
                        acc <= a_q * b_q;
                    else
                        acc <= acc + a_q * b_q;
                    if (k==7) k<=0;
                    else k<=k+1;
                    end
                end

                // Column DCT pass
                ST_DCTC: begin
                    if (ph == 2'd0) begin
                        a_q <= blk_dct[{k,c}];
                        b_q <= cos_table[{r,k}];
                        ph  <= 2'd1;
                    end else if (ph == 2'd2) begin
                        blk_out[{r,c}] <= acc[23:8];
                        ph <= 0;
                        if (c==7) begin
                            c<=0;
                            if (r==7) begin r<=0; c<=0; pix_cnt<=0;
                                store_addr<=output_addr_reg; state<=ST_STORE; end
                            else r<=r+1;
                        end else c<=c+1;
                    end else begin
                    ph <= (k==7) ? 2'd2 : 2'd0;
                    if (k==0)
                        acc <= a_q * b_q;
                    else
                        acc <= acc + a_q * b_q;
                    if (k==7) k<=0;
                    else k<=k+1;
                    end
                end

                // Store 64 coefficients (2 per word, 16-bit each → 32 words)
                ST_STORE: begin
                    bram_req  <= 1;
                    bram_we   <= 1;
                    // word addr = store_addr + row*out_row_stride + pair_in_row(0..3)
                    // (row = pix_cnt[5:3], pair_in_row = pix_cnt[2:1]; matches the
                    // original pix_cnt[5:1] exactly when out_row_stride==4)
                    bram_addr <= store_addr + ({26'b0, pix_cnt[5:3]} * out_row_stride_reg)
                                            + {28'b0, pix_cnt[2:1]};
                    bram_wdata<= {blk_out[{pix_cnt[5:1],1'b0}],
                                  blk_out[{pix_cnt[5:1],1'b1}]};
                    pix_cnt <= pix_cnt + 2;
                    if (pix_cnt >= 62) begin
                        busy<=0; done<=1; ctrl_reg[1]<=1; state<=ST_IDLE;
                    end
                end
            endcase
        end
    end
assign ready = ready_r;    
endmodule

// ============================================================================
// Generic simple-dual-port RAM, 1 write + 1 registered read, no reset.
// Kept as its own module so Vivado reliably infers block RAM.
// ============================================================================
module sdp_ram #(
    parameter W     = 16,
    parameter DEPTH = 1024,
    parameter AW    = 10
)(
    input               clk,
    input               we,
    input  [AW-1:0]     waddr,
    input  [W-1:0]      wdata,
    input  [AW-1:0]     raddr,
    output reg [W-1:0]  rdata
);
    (* ram_style = "block" *) reg [W-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule

// ============================================================================
// 19. CNN ACCELERATOR  (LeNet-5 Inference Engine)
//
// REGISTER MAP (MMIO 0x40000100):
//   0x00  CTRL:   [0]=start, [1]=done(RO)
//   0x04  STATUS: [0]=busy
//   0x08  INPUT_ADDR:  BRAM base address of DCT coefficients
//   0x0C  OUTPUT_ADDR: BRAM address for result
//   0x10  CLASS:  predicted class (0-9)
//   0x14  CONF:   confidence (Q16 fixed-point)
//
// Architecture: LeNet-5 inspired
//   Input:  32×32 from DCT-upscaled (or raw 8×8 padded)
//   Conv1:  6 feature maps, 5×5 kernel → 28×28
//   Pool1:  2×2 avg → 14×14
//   Conv2:  16 feature maps, 5×5 → 10×10
//   Pool2:  2×2 avg → 5×5
//   FC1:    120 neurons
//   FC2:    84 neurons
//   FC3:    10 output classes
//
// NOTE: Weights are loaded from weight BRAM at 0x40000180 address space
// ============================================================================
module cnn_accelerator(
    input         clk, rst,
    input         req, we,
    input  [7:0]  addr,
    input  [31:0] wdata,
    output reg [31:0] rdata,
    output     ready,

    // Shared BRAM port for activations
    output reg [31:0] bram_addr,
    output reg [31:0] bram_wdata,
    output reg        bram_we,
    input  [31:0]     bram_rdata,
    output reg        bram_req,

    // Weight ROM port
    output reg [31:0] wt_addr,
    input  [31:0]     wt_rdata,
    output reg        wt_req,

    // Seven-segment display interface
    output [3:0] class_out,
    output       done_out
);
    // ---- Weight ROM address map ----
    // Dense, non-overlapping word addresses generated by
    // gen_weight_rom.py / weight_addr_map.vh from the real int8
    // quantized LeNet-5 tensors. Each ROM word holds one weight or
    // bias, sign-extended from int8 into bits [15:0] (bits [31:16]=0).
    localparam WT_CONV1_W_BASE = 0,     WT_CONV1_B_BASE = 150;
    localparam WT_CONV2_W_BASE = 156,   WT_CONV2_B_BASE = 2556;
    localparam WT_FC1_W_BASE   = 2572,  WT_FC1_B_BASE   = 50572;
    localparam WT_FC2_W_BASE   = 50692, WT_FC2_B_BASE   = 60772;
    localparam WT_FC3_W_BASE   = 60856, WT_FC3_B_BASE   = 61696;

    // ---- Exact per-layer requantization constants ----
    // Derived from real weight/bias/activation calibration scales via
    // gen_requant_consts.py:
    //   main_factor = weight_scale * input_act_scale / output_act_scale
    //   bias_factor = bias_scale / output_act_scale          (conv1/2, fc1/2)
    //   bias_factor = bias_scale / (weight_scale*input_scale) (fc3 only --
    //                 no output act scale since fc3 emits raw logits)
    // Represented as integer M with a common Q(RQ_SHIFT) fractional shift:
    //   factor ~= M / 2^RQ_SHIFT
    /*localparam RQ_SHIFT = 24;
    localparam signed [31:0] RQ_M_CONV1 = 32'sd143574,  RQ_MB_CONV1 = 32'sd2013;
    localparam signed [31:0] RQ_M_CONV2 = 32'sd104841,  RQ_MB_CONV2 = 32'sd3420;
    localparam signed [31:0] RQ_M_FC1   = 32'sd74871,   RQ_MB_FC1   = 32'sd2263;
    localparam signed [31:0] RQ_M_FC2   = 32'sd155224,  RQ_MB_FC2   = 32'sd13275;
    localparam signed [31:0] RQ_MB_FC3  = 32'sd8262235;  // fc3: bias only, no main rescale*/
    
    //The new constants 
   localparam RQ_SHIFT = 24;
    localparam signed [31:0] RQ_M_CONV1  = 32'sd48007,  RQ_MB_CONV1 = 32'sd170569;
localparam signed [31:0] RQ_M_CONV2  = 32'sd251652,  RQ_MB_CONV2 = 32'sd277379;
localparam signed [31:0] RQ_M_FC1    = 32'sd346191,   RQ_MB_FC1   = 32'sd311678;
localparam signed [31:0] RQ_M_FC2    = 32'sd76091,  RQ_MB_FC2   = 32'sd466964;
localparam signed [31:0] RQ_MB_FC3   = 32'sd97593030;

//CIFAR10 constants
/*localparam RQ_SHIFT = 24;
localparam signed [31:0] RQ_M_CONV1  = 32'sd267642,  RQ_MB_CONV1 = 32'sd16322;
localparam signed [31:0] RQ_M_CONV2  = 32'sd743000,  RQ_MB_CONV2 = 32'sd51257;
localparam signed [31:0] RQ_M_FC1    = 32'sd292494,   RQ_MB_FC1   = 32'sd262791;
localparam signed [31:0] RQ_M_FC2    = 32'sd95372,  RQ_MB_FC2   = 32'sd357957;
localparam signed [31:0] RQ_MB_FC3   = 32'sd35346622;*/

    // Control registers
    reg [31:0] ctrl_reg, input_addr_reg, output_addr_reg;
    reg [31:0] class_reg, conf_reg;
    reg        busy, done;

    // ---- Per-stage activation buffers, sized for the FULL LeNet-5
    //      dataflow on a 32x32 assembled DCT frame (4x4 grid of 8x8
    //      blocks). Standard LeNet-5 shapes:
    //        32x32 -> conv1(6,5x5) -> 28x28x6 -> pool1 -> 14x14x6
    //              -> conv2(16,5x5)-> 10x10x16 -> pool2 -> 5x5x16(=400)
    //              -> fc1(400->120) -> fc2(120->84) -> fc3(84->10)
    // inbuf is split into even/odd banks (512 x 16 each) so that the two
    // coefficients packed in one BRAM word are written to different banks
    // (1 write port each) and the conv1 read uses 1 read port per bank.
    // inbuf_e/inbuf_o (512x16), c1buf (4704x16), p1buf (1176x16), c2buf (1600x16)
    // now live in sdp_ram instances below (one BRAM-template module each).
    reg signed [15:0] p2buf  [0:399];   // 16 x 5 x 5   pool2 out / FC1 input
    reg signed [15:0] fc1buf [0:119];   // FC1 out (post ReLU)
    reg signed [15:0] fc2buf [0:83];    // FC2 out (post ReLU)
    reg signed [31:0] fc_out [0:9];     // FC3 logits (no rescale -- argmax input)

    localparam
        ST_IDLE  = 4'd0,
        ST_LOAD  = 4'd1,
        ST_C1    = 4'd2,  // Conv1
        ST_P1    = 4'd3,  // Pool1
        ST_C2    = 4'd4,  // Conv2
        ST_P2    = 4'd5,  // Pool2
        ST_FC1   = 4'd6,
        ST_FC2   = 4'd7,
        ST_FC3   = 4'd8,
        ST_ARGMAX= 4'd9,
        ST_STORE = 4'd10;

    reg [3:0]  state;
    reg [3:0]  fm;         // output feature-map / channel index (0-15)
    reg [4:0]  row, col;   // output spatial index (0-27)
    reg [2:0]  ky, kx;     // kernel tap index (0-4)
    reg [2:0]  ci;         // conv2 input-channel index (0-5)
    reg [9:0]  neuron;     // FC neuron / output index
    reg [9:0]  pix_cnt;          // generic secondary counter: BRAM word index
                            // during ST_LOAD (0-511), FC input-vector index
                            // during ST_FC1/2/3 (0-399/119/83)
    reg [2:0]  tap_phase;  // 0=issue addr, 1=wait 1 cycle (BRAM/ROM latency), 2=use rdata
                           // bias path only: 3=requant add/ReLU settles, 4=write result
    reg        bias_phase; // 0=accumulating taps, 1=fetching+applying bias
    reg signed [31:0] mac_acc;
    reg ready_r;
    reg req_prev;

    // ReLU. Values are expected to stay within 16 bits after the >>8
    // rescale given the DCT coefficient dynamic range this project has
    // observed; there's no saturation guard here, matching the original
    // accelerator's style -- flag for hardening before real synthesis.
    function signed [15:0] relu16;
        input signed [31:0] x;
        relu16 = x[31] ? 16'sd0 : x[15:0];
    endfunction

    // ReLU on the wide (post-rescale) accumulator: sign-check on the full
    // 64-bit value (not just the truncated low bits), then truncate to 16.
    function signed [15:0] relu_wide;
        input signed [63:0] x;
        relu_wide = x[63] ? 16'sd0 : x[15:0];
    endfunction

    // ------------------------------------------------------------------
    // Pipelined requantization (timing fix). The old single-cycle path was
    // ROM -> 32x32 multiply -> 64-bit add -> ReLU sign -> fan-out to the
    // buffer write enables (~14 ns). Now split into registers:
    //   phase 2: rq_pa / rq_pb   <= the two products   (DSP48 + P register)
    //   phase 3: rq_val          <= ReLU((pa+pb+round) >>> RQ_SHIFT)
    //   phase 4: buffer          <= rq_val
    // rq_val is free-running; it is only consumed in phase 4, one cycle after
    // rq_pa/rq_pb were last loaded, so the arithmetic is bit-identical.
    // ------------------------------------------------------------------
    reg signed [63:0] rq_pa, rq_pb;
    reg signed [15:0] rq_val;
    reg signed [15:0] ma_hi, wq;
    reg        [15:0] ma_lo;
    reg signed [63:0] pa_hi, pa_lo;
    always @(posedge clk) rq_pa <= (pa_hi <<< 16) + pa_lo;
    always @(posedge clk)
        rq_val <= relu_wide((rq_pa + rq_pb + (64'sd1 <<< (RQ_SHIFT-1))) >>> RQ_SHIFT);

    // ------------------------------------------------------------------
    // BRAM-inferable memory ports (1 write + 1 registered read each,
    // no reset). All accesses to inbuf/c1buf/p1buf/c2buf go through here.
    // ------------------------------------------------------------------
    reg [2:0]         p_phase;    // pooling micro-sequencer (shared by P1/P2)
    reg signed [15:0] pool_acc;   // 16-bit on purpose: bit-exact with the old
                                  // 16-bit-context sum in the original code

    // inbuf: written in ST_LOAD (2 words/cycle -> one per bank)
    wire        in_we    = (state==ST_LOAD) && (tap_phase==2'd2);
    wire [8:0]  in_waddr = pix_cnt[8:0];
    // inbuf: conv1 read. idx stable during tap phases 0..2, read lands in phase 2
    wire [9:0]  in_idx   = (row+ky)*32 + (col+kx);
    wire signed [15:0] in_e_q, in_o_q;
    wire signed [15:0] in_rdata = in_idx[0] ? in_o_q : in_e_q;
    sdp_ram #(.W(16),.DEPTH(512),.AW(9)) INBUF_E (
        .clk(clk), .we(in_we), .waddr(in_waddr), .wdata(bram_rdata[31:16]),
        .raddr(in_idx[9:1]), .rdata(in_e_q));   // even pixel
    sdp_ram #(.W(16),.DEPTH(512),.AW(9)) INBUF_O (
        .clk(clk), .we(in_we), .waddr(in_waddr), .wdata(bram_rdata[15:0]),
        .raddr(in_idx[9:1]), .rdata(in_o_q));   // odd pixel

    // c1buf: written when conv1 finishes a pixel, read by pool1
    wire        c1_we    = (state==ST_C1) && bias_phase && (tap_phase==3'd6);
    wire [12:0] c1_waddr = fm*784 + row*28 + col;
    wire signed [15:0] c1_wdata = rq_val;
    reg  [12:0] c1_raddr;
    wire signed [15:0] c1_rdata;
    sdp_ram #(.W(16),.DEPTH(4704),.AW(13)) C1BUF (
        .clk(clk), .we(c1_we), .waddr(c1_waddr), .wdata(c1_wdata),
        .raddr(c1_raddr), .rdata(c1_rdata));

    // p1buf: written by pool1, read by conv2
    wire        p1_we    = (state==ST_P1) && (p_phase==3'd5);
    wire [10:0] p1_waddr = fm*196 + row*14 + col;
    wire signed [15:0] pool1_sum = pool_acc + c1_rdata;
    wire signed [15:0] p1_wdata  = pool1_sum >>> 2;
    wire [10:0] p1_raddr = ci*196 + (row+ky)*14 + (col+kx);
    wire signed [15:0] p1_rdata;
    sdp_ram #(.W(16),.DEPTH(1176),.AW(11)) P1BUF (
        .clk(clk), .we(p1_we), .waddr(p1_waddr), .wdata(p1_wdata),
        .raddr(p1_raddr), .rdata(p1_rdata));

    // c2buf: written when conv2 finishes a pixel, read by pool2
    wire        c2_we    = (state==ST_C2) && bias_phase && (tap_phase==3'd6);
    wire [10:0] c2_waddr = fm*100 + row*10 + col;
    wire signed [15:0] c2_wdata = rq_val;
    reg  [10:0] c2_raddr;
    wire signed [15:0] c2_rdata;
    reg signed [15:0] p2_q;
    reg [8:0] p2_idx;
    wire signed [15:0] pool2_sum = pool_acc + c2_rdata;
    sdp_ram #(.W(16),.DEPTH(1600),.AW(11)) C2BUF (
        .clk(clk), .we(c2_we), .waddr(c2_waddr), .wdata(c2_wdata),
        .raddr(c2_raddr), .rdata(c2_rdata));

    // ------------------------------------------------------------------
    // Registered MAC operands (timing fix). Per tap:
    //   phase 0: issue weight address       phase 1: wait
    //   phase 2: latch mul_a / mul_b        phase 3: mac_acc += mul_a*mul_b, advance
    // act_q pre-registers the FC activation (400:1 / 120:1 / 84:1 muxes) --
    // pix_cnt is stable for phases 0..2, so act_q is valid by phase 2.
    // ------------------------------------------------------------------
    reg signed [15:0] act_q;
    always @(posedge clk)
        case (state)
            ST_FC1:  act_q <= p2buf[pix_cnt];
            ST_FC2:  act_q <= fc1buf[pix_cnt];
            ST_FC3:  act_q <= fc2buf[pix_cnt];
            default: act_q <= 16'sd0;
        endcase
    wire signed [15:0] mac_a = (state==ST_C1) ? in_rdata :
                               (state==ST_C2) ? p1_rdata : act_q;
    reg signed [15:0] mul_a, mul_b;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ready_r <= 0;req_prev<=0;state<=ST_IDLE; busy<=0; done<=0; 
            ctrl_reg<=0; input_addr_reg<=0; output_addr_reg<=0;
            class_reg<=0; conf_reg<=0;
            bram_req<=0; bram_we<=0; wt_req<=0;
            fm<=0; row<=0; col<=0; ky<=0; kx<=0; ci<=0;
            neuron<=0; pix_cnt<=0; tap_phase<=0; bias_phase<=0; mac_acc<=0;
            p_phase<=0; pool_acc<=0; c1_raddr<=0; c2_raddr<=0;
        end else begin
            req_prev <= req;
        ready_r  <= req | req_prev;bram_req<=0; bram_we<=0; wt_req<=0;

            // Register interface
            if (req) begin
                if (we) case(addr[7:0])
                    8'h00: ctrl_reg       <= wdata;
                    8'h08: input_addr_reg <= wdata;
                    8'h0C: output_addr_reg<= wdata;
                endcase
                else case(addr[7:0])
                    8'h00: rdata <= ctrl_reg;
                    8'h04: rdata <= {31'b0, busy};
                    8'h08: rdata <= input_addr_reg;
                    8'h0C: rdata <= output_addr_reg;
                    8'h10: rdata <= class_reg;
                    8'h14: rdata <= conf_reg;
                    default: rdata<=0;
                endcase
            end

            case (state)
                ST_IDLE: begin
                    done<=0;
                    if (ctrl_reg[0] && !busy) begin
                        busy<=1; pix_cnt<=0; tap_phase<=0; ctrl_reg[0]<=0;
                        state<=ST_LOAD;
                    end
                end

                // Load 1024 input activations (32x32 assembled DCT frame)
                // from BRAM, 2 coefficients packed per 32-bit word (matching
                // dct_accelerator's ST_STORE packing). Explicit 3-phase
                // issue/wait/use per word to safely cross the 1-cycle
                // registered-BRAM-read latency.
                ST_LOAD: begin
                    case (tap_phase)
                        2'd0: begin
                            bram_req  <= 1;
                            bram_addr <= input_addr_reg + {22'b0, pix_cnt};
                            bram_we   <= 0;
                            tap_phase <= 1;
                        end
                        2'd1: tap_phase <= 2;
                        2'd2: begin
                            // inbuf_e/inbuf_o written in memory block (in_we)
                            if (pix_cnt == 511) begin
                                pix_cnt<=0; fm<=0; row<=0; col<=0; ky<=0; kx<=0;
                                tap_phase<=0; bias_phase<=0; mac_acc<=0;
                                state<=ST_C1;
                            end else begin
                                pix_cnt<=pix_cnt+1; tap_phase<=0;
                            end
                        end
                    endcase
                end

                // ---- Conv1: 6 filters, 1 input channel, 5x5 valid -> 28x28x6 ----
                ST_C1: begin
                    if (!bias_phase) begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_CONV1_W_BASE + fm*25 + ky*5 + kx;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin
                                mul_a <= mac_a; mul_b <= $signed(wt_rdata[15:0]);
                                tap_phase <= 3;
                            end
                            3'd3: begin
                                mac_acc <= mac_acc + $signed(mul_a) * $signed(mul_b);
                                if (kx==4) begin
                                    kx<=0;
                                    if (ky==4) begin ky<=0; bias_phase<=1; tap_phase<=0; end
                                    else begin ky<=ky+1; tap_phase<=0; end
                                end else begin kx<=kx+1; tap_phase<=0; end
                            end
                        endcase
                    end else begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_CONV1_B_BASE + fm;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin ma_hi <= mac_acc[31:16]; ma_lo <= mac_acc[15:0]; wq <= $signed(wt_rdata[15:0]); tap_phase <= 3; end
                            3'd3: begin pa_hi <= ma_hi * RQ_M_CONV1; pa_lo <= $signed({1'b0,ma_lo}) * RQ_M_CONV1; rq_pb <= wq * RQ_MB_CONV1; tap_phase <= 4; end
                            3'd4: tap_phase <= 5;
                            3'd5: tap_phase <= 6;
                            3'd6: begin
                                // c1buf written in memory block (c1_we)
                                mac_acc<=0; bias_phase<=0; tap_phase<=0;
                                if (col==27) begin col<=0;
                                    if (row==27) begin row<=0;
                                        if (fm==5) begin fm<=0; state<=ST_P1; end
                                        else fm<=fm+1;
                                    end else row<=row+1;
                                end else col<=col+1;
                            end
                        endcase
                    end
                end

                // ---- Pool1: 2x2 average, 6x28x28 -> 6x14x14 ----
                ST_P1: begin
                    case (p_phase)
                        3'd0: begin c1_raddr <= fm*784 + (2*row)*28 + 2*col; p_phase <= 1; end
                        3'd1: begin c1_raddr <= c1_raddr + 1;  p_phase <= 2; end
                        3'd2: begin pool_acc <= c1_rdata;
                                    c1_raddr <= c1_raddr + 27; p_phase <= 3; end
                        3'd3: begin pool_acc <= pool_acc + c1_rdata;
                                    c1_raddr <= c1_raddr + 1;  p_phase <= 4; end
                        3'd4: begin pool_acc <= pool_acc + c1_rdata; p_phase <= 5; end
                        3'd5: begin
                            // p1buf written in memory block (p1_we)
                            p_phase <= 0;
                            if (col==13) begin col<=0;
                                if (row==13) begin row<=0;
                                    if (fm==5) begin
                                        fm<=0; ky<=0; kx<=0; ci<=0;
                                        tap_phase<=0; bias_phase<=0; mac_acc<=0;
                                        state<=ST_C2;
                                    end else fm<=fm+1;
                                end else row<=row+1;
                            end else col<=col+1;
                        end
                        default: p_phase <= 0;
                    endcase
                end

                // ---- Conv2: 16 filters, 6 input channels, 5x5 valid -> 10x10x16 ----
                ST_C2: begin
                    if (!bias_phase) begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_CONV2_W_BASE + fm*150 + ci*25 + ky*5 + kx;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin
                                mul_a <= mac_a; mul_b <= $signed(wt_rdata[15:0]);
                                tap_phase <= 3;
                            end
                            3'd3: begin
                                mac_acc <= mac_acc + $signed(mul_a) * $signed(mul_b);
                                if (kx==4) begin
                                    kx<=0;
                                    if (ky==4) begin
                                        ky<=0;
                                        if (ci==5) begin ci<=0; bias_phase<=1; tap_phase<=0; end
                                        else begin ci<=ci+1; tap_phase<=0; end
                                    end else begin ky<=ky+1; tap_phase<=0; end
                                end else begin kx<=kx+1; tap_phase<=0; end
                            end
                        endcase
                    end else begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_CONV2_B_BASE + fm;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin ma_hi <= mac_acc[31:16]; ma_lo <= mac_acc[15:0]; wq <= $signed(wt_rdata[15:0]); tap_phase <= 3; end
                            3'd3: begin pa_hi <= ma_hi * RQ_M_CONV2; pa_lo <= $signed({1'b0,ma_lo}) * RQ_M_CONV2; rq_pb <= wq * RQ_MB_CONV2; tap_phase <= 4; end
                            3'd4: tap_phase <= 5;
                            3'd5: tap_phase <= 6;
                            3'd6: begin
                                // c2buf written in memory block (c2_we)
                                mac_acc<=0; bias_phase<=0; tap_phase<=0;
                                if (col==9) begin col<=0;
                                    if (row==9) begin row<=0;
                                        if (fm==15) begin fm<=0; state<=ST_P2; end
                                        else fm<=fm+1;
                                    end else row<=row+1;
                                end else col<=col+1;
                            end
                        endcase
                    end
                end

                // ---- Pool2: 2x2 average, 16x10x10 -> 16x5x5 (flatten = FC1 input) ----
                ST_P2: begin
                    case (p_phase)
                        3'd0: begin c2_raddr <= fm*100 + (2*row)*10 + 2*col; p_phase <= 1; end
                        3'd1: begin c2_raddr <= c2_raddr + 1;  p_phase <= 2; end
                        3'd2: begin pool_acc <= c2_rdata;
                                    c2_raddr <= c2_raddr + 9;  p_phase <= 3; end
                        3'd3: begin pool_acc <= pool_acc + c2_rdata;
                                    c2_raddr <= c2_raddr + 1;  p_phase <= 4; end
                        3'd4: begin pool_acc <= pool_acc + c2_rdata; p_phase <= 5; end
                        3'd5: begin
                            p2_q   <= pool2_sum >>> 2;
                            p2_idx <= fm*25 + row*5 + col;
                            p_phase <= 6;
                        end
                        3'd6: begin
                            p2buf[p2_idx] <= p2_q;
                            p_phase <= 0;
                            if (col==4) begin col<=0;
                                if (row==4) begin row<=0;
                                    if (fm==15) begin
                                        fm<=0; neuron<=0; pix_cnt<=0;
                                        tap_phase<=0; bias_phase<=0; mac_acc<=0;
                                        state<=ST_FC1;
                                    end else fm<=fm+1;
                                end else row<=row+1;
                            end else col<=col+1;
                        end
                        default: p_phase <= 0;
                    endcase
                end

                // ---- FC1: 400 -> 120 ----
                ST_FC1: begin
                    if (!bias_phase) begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_FC1_W_BASE + neuron*400 + pix_cnt;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin
                                mul_a <= mac_a; mul_b <= $signed(wt_rdata[15:0]);
                                tap_phase <= 3;
                            end
                            3'd3: begin
                                mac_acc <= mac_acc + $signed(mul_a) * $signed(mul_b);
                                if (pix_cnt==399) begin pix_cnt<=0; bias_phase<=1; tap_phase<=0; end
                                else begin pix_cnt<=pix_cnt+1; tap_phase<=0; end
                            end
                        endcase
                    end else begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_FC1_B_BASE + neuron;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin ma_hi <= mac_acc[31:16]; ma_lo <= mac_acc[15:0]; wq <= $signed(wt_rdata[15:0]); tap_phase <= 3; end
                            3'd3: begin pa_hi <= ma_hi * RQ_M_FC1; pa_lo <= $signed({1'b0,ma_lo}) * RQ_M_FC1; rq_pb <= wq * RQ_MB_FC1; tap_phase <= 4; end
                            3'd4: tap_phase <= 5;
                            3'd5: tap_phase <= 6;
                            3'd6: begin
                                fc1buf[neuron] <= rq_val;
                                mac_acc<=0; bias_phase<=0; tap_phase<=0; pix_cnt<=0;
                                if (neuron==119) begin neuron<=0; state<=ST_FC2; end
                                else neuron<=neuron+1;
                            end
                        endcase
                    end
                end

                // ---- FC2: 120 -> 84 ----
                ST_FC2: begin
                    if (!bias_phase) begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_FC2_W_BASE + neuron*120 + pix_cnt;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin
                                mul_a <= mac_a; mul_b <= $signed(wt_rdata[15:0]);
                                tap_phase <= 3;
                            end
                            3'd3: begin
                                mac_acc <= mac_acc + $signed(mul_a) * $signed(mul_b);
                                if (pix_cnt==119) begin pix_cnt<=0; bias_phase<=1; tap_phase<=0; end
                                else begin pix_cnt<=pix_cnt+1; tap_phase<=0; end
                            end
                        endcase
                    end else begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_FC2_B_BASE + neuron;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin ma_hi <= mac_acc[31:16]; ma_lo <= mac_acc[15:0]; wq <= $signed(wt_rdata[15:0]); tap_phase <= 3; end
                            3'd3: begin pa_hi <= ma_hi * RQ_M_FC2; pa_lo <= $signed({1'b0,ma_lo}) * RQ_M_FC2; rq_pb <= wq * RQ_MB_FC2; tap_phase <= 4; end
                            3'd4: tap_phase <= 5;
                            3'd5: tap_phase <= 6;
                            3'd6: begin
                                fc2buf[neuron] <= rq_val;
                                mac_acc<=0; bias_phase<=0; tap_phase<=0; pix_cnt<=0;
                                if (neuron==83) begin neuron<=0; state<=ST_FC3; end
                                else neuron<=neuron+1;
                            end
                        endcase
                    end
                end

                // ---- FC3: 84 -> 10 (raw logits -- no rescale/ReLU, used by argmax) ----
                ST_FC3: begin
                    if (!bias_phase) begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_FC3_W_BASE + neuron*84 + pix_cnt;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin
                                mul_a <= mac_a; mul_b <= $signed(wt_rdata[15:0]);
                                tap_phase <= 3;
                            end
                            3'd3: begin
                                mac_acc <= mac_acc + $signed(mul_a) * $signed(mul_b);
                                if (pix_cnt==83) begin pix_cnt<=0; bias_phase<=1; tap_phase<=0; end
                                else begin pix_cnt<=pix_cnt+1; tap_phase<=0; end
                            end
                        endcase
                    end else begin
                        case (tap_phase)
                            2'd0: begin
                                wt_req  <= 1;
                                wt_addr <= WT_FC3_B_BASE + neuron;
                                tap_phase <= 1;
                            end
                            2'd1: tap_phase <= 2;
                            2'd2: begin
                                rq_pb <= $signed(wt_rdata[15:0]) * RQ_MB_FC3;
                                tap_phase <= 3;
                            end
                            3'd3: begin
                                // fc3 emits raw logits (no output scale; argmax only). Bias converted
                                // into mac_acc units via RQ_MB_FC3 before adding.
                                fc_out[neuron] <= mac_acc +
                                    ((rq_pb + (64'sd1 <<< (RQ_SHIFT-1))) >>> RQ_SHIFT);
                                mac_acc<=0; bias_phase<=0; tap_phase<=0;
                                if (neuron==9) begin neuron<=0; state<=ST_ARGMAX; end
                                else neuron<=neuron+1;
                            end
                        endcase
                    end
                end

                // Argmax: find highest logit
                ST_ARGMAX: begin
                    if (neuron==0) begin mac_acc<=fc_out[0]; class_reg<=0; end
                    else if (fc_out[neuron] > mac_acc) begin
                        mac_acc<=fc_out[neuron]; class_reg<={28'b0,neuron[3:0]};
                    end
                    if (neuron>=9) begin
                        conf_reg <= mac_acc[31:0]; // raw logit as confidence
                        ctrl_reg[1]<=1; state<=ST_STORE;
                    end else neuron<=neuron+1;
                end

                // Write result to BRAM
                ST_STORE: begin
                    bram_req  <=1; bram_we<=1;
                    bram_addr <= output_addr_reg;
                    bram_wdata<= class_reg;
                    busy<=0; done<=1; state<=ST_IDLE;
                end
            endcase
        end
    end
    assign ready    = ready_r;
    assign class_out = class_reg[3:0];
    assign done_out  = done;

endmodule
module bram_arbiter #(
    parameter DEPTH = 4096
)(
    input         clk, rst,
    input         cpu_req, cpu_we,
    input  [31:0] cpu_addr,
    input  [31:0] cpu_wdata,
    output reg [31:0] cpu_rdata,
    input         acc_req, acc_we,
    input  [31:0] acc_addr,
    input  [31:0] acc_wdata,
    output reg [31:0] acc_rdata,
    output reg    acc_grant
);
    // FIX 1: ram_style attribute + no reset loop
    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH-1];

    wire [31:0] cpu_word = cpu_addr >> 2;   // CPU/DMA side IS byte-addressed (from MMIO bus)
    // NOTE (bug fix): acc_addr from DCT/CNN is already a WORD index -- their
    // own address arithmetic (e.g. dct_accelerator's `load_addr + pix_cnt[5:2]`)
    // never scales by 4. The previous `acc_addr >> 2` here silently divided
    // every accelerator-side address by 4 again, colliding every 4 consecutive
    // intended word accesses onto the same physical BRAM word. This has been
    // corrupting every DCT/CNN <-> shared-BRAM transaction since before this
    // session; confirmed via tb_frame_controller.v's direct BRAM readback.
    wire [31:0] acc_word = acc_addr;

    // FIX 2: Control signal - reset is fine here (no RAM array)
    always @(posedge clk or posedge rst) begin
        if (rst) acc_grant <= 0;
        else     acc_grant <= acc_req && !cpu_req;
    end

    // True dual-port BRAM: one process per port (this is what Vivado maps to
    // RAMB36 TDP; a single process with if/else-if write priority becomes
    // distributed RAM). Behaviour is unchanged: CPU/DMA write has priority --
    // the accelerator write is simply gated off while cpu_req is high.
    localparam AW = $clog2(DEPTH);
    wire cpu_in = (cpu_word < DEPTH);
    wire acc_in = (acc_word < DEPTH);

    // Port A: CPU / DMA
    always @(posedge clk) begin
        if (cpu_req && cpu_we && cpu_in)
            mem[cpu_word[AW-1:0]] <= cpu_wdata;
        cpu_rdata <= mem[cpu_word[AW-1:0]];
    end

    // Port B: DCT / CNN accelerators
    always @(posedge clk) begin
        if (acc_req && !cpu_req && acc_we && acc_in)
            mem[acc_word[AW-1:0]] <= acc_wdata;
        acc_rdata <= mem[acc_word[AW-1:0]];
    end

endmodule
// ============================================================================
// 20. FRAME CONTROLLER  (4x4-grid-of-8x8-blocks orchestrator)
//
// REGISTER MAP (MMIO 0x40000500):
//   0x00  CTRL:      [0]=start, [1]=done(RO)
//   0x04  STATUS:    [0]=busy
//   0x08  RAW_ADDR:  BRAM base word address of the 32x32 raw pixel image
//                    (8 words/row x 32 rows = 256 words, 4 px/word)
//   0x0C  COEF_ADDR: BRAM base word address of the assembled 32x32 DCT
//                    coefficient frame (16 words/row x 32 rows = 512 words,
//                    2 coeffs/word) -- also becomes CNN's input address
//   0x10  OUT_ADDR:  BRAM address to write the final classification byte
//   0x14  CLASS:     mirrors CNN's class_reg once done (RO)
//
// On a single CTRL[0]=1 trigger, this module:
//   1. Walks a 4x4 grid of 8x8 blocks, reprogramming dct_accelerator's
//      input/output addresses and row-stride registers per block (so DCT,
//      which only knows how to transform one contiguous 8x8 block, can be
//      pointed at a sub-block sitting inside the larger 32x32 image/frame),
//      and running it to completion before moving to the next block.
//   2. Once all 16 blocks are done, points cnn_accelerator at the now-
//      complete 32x32 coefficient frame and runs it to completion.
//   3. Copies the CNN's classification result into its own CLASS register
//      and asserts DONE.
//
// This exists so firmware only has to trigger ONE register (instead of
// hand-looping 16 DCT invocations + 1 CNN invocation in machine code).
// While busy, this module becomes the sole master of DCT's and CNN's
// register interfaces (see frame_active mux in riscv_soc.v) -- firmware
// must not poke DCT/CNN directly while a frame is in flight.
// ============================================================================
module frame_controller(
    input         clk, rst,
    // CPU-facing register interface (through mmio_controller)
    input         req, we,
    input  [7:0]  addr,
    input  [31:0] wdata,
    output reg [31:0] rdata,
    output        ready,
    // Master port toward dct_accelerator's register interface
    output reg        dctm_req, dctm_we,
    output reg [7:0]  dctm_addr,
    output reg [31:0] dctm_wdata,
    input      [31:0] dctm_rdata,
    // Master port toward cnn_accelerator's register interface
    output reg        cnnm_req, cnnm_we,
    output reg [7:0]  cnnm_addr,
    output reg [31:0] cnnm_wdata,
    input      [31:0] cnnm_rdata,
    // High while this controller owns DCT/CNN's register ports (drives the
    // CPU-vs-frame_controller mux in riscv_soc.v)
    output            frame_active
);
    reg [31:0] ctrl_reg, raw_addr_reg, coef_addr_reg, out_addr_reg, class_reg;
    reg        busy, done;
    reg        ready_r, req_prev;

    reg [2:0]  blk_row, blk_col;   // 0..3
    reg [1:0]  rd_phase;           // 0=issue read, 1=sample rdata (polling states);
                                    // 0=issue, 1=settle, 2=sample (ST_CNN_RD_CLASS --
                                    // see fix note below)
    reg        seen_busy;          // guards against sampling busy=0 before DCT/CNN has actually started

    localparam
        ST_IDLE          = 4'd0,
        ST_DCT_SET_IN    = 4'd1,
        ST_DCT_SET_OUT   = 4'd2,
        ST_DCT_SET_ISTR  = 4'd3,
        ST_DCT_SET_OSTR  = 4'd4,
        ST_DCT_START     = 4'd5,
        ST_DCT_POLL_BUSY = 4'd6,
        ST_DCT_POLL_DONE = 4'd7,
        ST_DCT_NEXT      = 4'd8,
        ST_CNN_SET_IN    = 4'd9,
        ST_CNN_SET_OUT   = 4'd10,
        ST_CNN_START     = 4'd11,
        ST_CNN_POLL_BUSY = 4'd12,
        ST_CNN_POLL_DONE = 4'd13,
        ST_CNN_RD_CLASS  = 4'd14,
        ST_DONE          = 4'd15;
    reg [3:0] state;

    assign frame_active = busy;
    assign ready = ready_r;

    // Per-block base addresses (word-addressed):
    //   raw image:   8 words/row  (32px/4 per word), 8 rows/block  -> row-of-blocks stride = 64 words
    //                                                                block-column stride    = 2 words
    //   coeff frame: 16 words/row (32coef/2 per word), 8 rows/block -> row-of-blocks stride = 128 words
    //                                                                block-column stride    = 4 words
    wire [31:0] blk_in_addr  = raw_addr_reg  + ({29'b0, blk_row} * 32'd64)  + ({29'b0, blk_col} * 32'd2);
    wire [31:0] blk_out_addr = coef_addr_reg + ({29'b0, blk_row} * 32'd128) + ({29'b0, blk_col} * 32'd4);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ready_r<=0; req_prev<=0; state<=ST_IDLE;
            ctrl_reg<=0; raw_addr_reg<=0; coef_addr_reg<=0; out_addr_reg<=0; class_reg<=0;
            busy<=0; done<=0;
            dctm_req<=0; dctm_we<=0; dctm_addr<=0; dctm_wdata<=0;
            cnnm_req<=0; cnnm_we<=0; cnnm_addr<=0; cnnm_wdata<=0;
            blk_row<=0; blk_col<=0; rd_phase<=0; seen_busy<=0;
        end else begin
            req_prev <= req; ready_r <= req | req_prev;
            dctm_req <= 0; cnnm_req <= 0;

            // CPU-facing register interface
            if (req) begin
                if (we) case (addr[7:0])
                    8'h00: ctrl_reg      <= wdata;
                    8'h08: raw_addr_reg  <= wdata;
                    8'h0C: coef_addr_reg <= wdata;
                    8'h10: out_addr_reg  <= wdata;
                endcase
                else 
                case (addr[7:0])
                    8'h00: rdata <= ctrl_reg;
                    8'h04: rdata <= {31'b0, busy};
                    8'h08: rdata <= raw_addr_reg;
                    8'h0C: rdata <= coef_addr_reg;
                    8'h10: rdata <= out_addr_reg;
                    8'h14: rdata <= class_reg;
                    default: rdata <= 0;
                endcase
            end

            case (state)
                ST_IDLE: begin
                    done <= 0;
                    if (ctrl_reg[0] && !busy) begin
                        busy <= 1; ctrl_reg[0] <= 0;
                        blk_row <= 0; blk_col <= 0;
                        state <= ST_DCT_SET_IN;
                    end
                end

                // ---- Program DCT for the current 8x8 block, then run it ----
                ST_DCT_SET_IN: begin
                    dctm_req<=1; dctm_we<=1; dctm_addr<=8'h08; dctm_wdata<=blk_in_addr;
                    state <= ST_DCT_SET_OUT;
                end
                ST_DCT_SET_OUT: begin
                    dctm_req<=1; dctm_we<=1; dctm_addr<=8'h0C; dctm_wdata<=blk_out_addr;
                    state <= ST_DCT_SET_ISTR;
                end
                ST_DCT_SET_ISTR: begin
                    dctm_req<=1; dctm_we<=1; dctm_addr<=8'h14; dctm_wdata<=32'd8;  // full-image row stride (words)
                    state <= ST_DCT_SET_OSTR;
                end
                ST_DCT_SET_OSTR: begin
                    dctm_req<=1; dctm_we<=1; dctm_addr<=8'h18; dctm_wdata<=32'd16; // full-frame row stride (words)
                    state <= ST_DCT_START;
                end
                ST_DCT_START: begin
                    dctm_req<=1; dctm_we<=1; dctm_addr<=8'h00; dctm_wdata<=32'd1; // ctrl[0]=start
                    seen_busy<=0; rd_phase<=0;
                    state <= ST_DCT_POLL_BUSY;
                end
                ST_DCT_POLL_BUSY: begin
                    case (rd_phase)
                        1'd0: begin dctm_req<=1; dctm_we<=0; dctm_addr<=8'h04; rd_phase<=1; end
                        1'd1: begin
                            if (dctm_rdata[0]) begin seen_busy<=1; state<=ST_DCT_POLL_DONE; end
                            rd_phase<=0;
                        end
                    endcase
                end
                ST_DCT_POLL_DONE: begin
                    case (rd_phase)
                        1'd0: begin dctm_req<=1; dctm_we<=0; dctm_addr<=8'h04; rd_phase<=1; end
                        1'd1: begin
                            if (seen_busy && !dctm_rdata[0]) state<=ST_DCT_NEXT;
                            rd_phase<=0;
                        end
                    endcase
                end
                ST_DCT_NEXT: begin
                    if (blk_col==3) begin
                        blk_col<=0;
                        if (blk_row==3) begin
                            blk_row<=0; state<=ST_CNN_SET_IN;
                        end else begin blk_row<=blk_row+1; state<=ST_DCT_SET_IN; end
                    end else begin blk_col<=blk_col+1; state<=ST_DCT_SET_IN; end
                end

                // ---- Program CNN for the assembled 32x32 frame, then run it ----
                ST_CNN_SET_IN: begin
                    cnnm_req<=1; cnnm_we<=1; cnnm_addr<=8'h08; cnnm_wdata<=coef_addr_reg;
                    state <= ST_CNN_SET_OUT;
                end
                ST_CNN_SET_OUT: begin
                    cnnm_req<=1; cnnm_we<=1; cnnm_addr<=8'h0C; cnnm_wdata<=out_addr_reg;
                    state <= ST_CNN_START;
                end
                ST_CNN_START: begin
                    cnnm_req<=1; cnnm_we<=1; cnnm_addr<=8'h00; cnnm_wdata<=32'd1;
                    seen_busy<=0; rd_phase<=0;
                    state <= ST_CNN_POLL_BUSY;
                end
                ST_CNN_POLL_BUSY: begin
                    case (rd_phase)
                        1'd0: begin cnnm_req<=1; cnnm_we<=0; cnnm_addr<=8'h04; rd_phase<=1; end
                        1'd1: begin
                            if (cnnm_rdata[0]) begin seen_busy<=1; state<=ST_CNN_POLL_DONE; end
                            rd_phase<=0;
                        end
                    endcase
                end
                ST_CNN_POLL_DONE: begin
                    case (rd_phase)
                        1'd0: begin cnnm_req<=1; cnnm_we<=0; cnnm_addr<=8'h04; rd_phase<=1; end
                        1'd1: begin
                            if (seen_busy && !cnnm_rdata[0]) state<=ST_CNN_RD_CLASS;
                            rd_phase<=0;
                        end
                    endcase
                end
                // FIX: this is a single-shot read of a FRESH address (0x10) issued
                // immediately after ST_CNN_POLL_DONE's repeated polling of a
                // DIFFERENT address (0x04). cnn_accelerator only updates its
                // registered `rdata` on the clock edge AFTER it samples `req`, and
                // nonblocking-assignment semantics mean a same-edge read of
                // cnnm_rdata by frame_controller observes the value from BEFORE
                // that edge -- i.e. CNN's *previous* response (stale busy=0 from
                // the last poll), not the freshly requested class value. The old
                // 2-phase (issue, sample) pattern masked this for busy-polling
                // only because it kept re-requesting the SAME address every
                // round, so the staleness silently self-corrected one iteration
                // later. A one-shot read of a NEW address has no such second
                // chance: frame_controller's class_reg mirror was landing on the
                // stale value (0) instead of CNN's real result, even though CNN's
                // own class_reg (and the BRAM copy from ST_STORE) were correct.
                // Adding an explicit settle phase gives CNN's rdata one full
                // extra cycle to actually reflect this request before sampling.
                ST_CNN_RD_CLASS: begin
                    case (rd_phase)
                        2'd0: begin cnnm_req<=1; cnnm_we<=0; cnnm_addr<=8'h10; rd_phase<=1; end
                        2'd1: rd_phase<=2;
                        2'd2: begin class_reg<=cnnm_rdata; state<=ST_DONE; rd_phase<=0; end
                    endcase
                end

                ST_DONE: begin
                    busy<=0; done<=1; state<=ST_IDLE;
                end
            endcase
        end
    end
endmodule