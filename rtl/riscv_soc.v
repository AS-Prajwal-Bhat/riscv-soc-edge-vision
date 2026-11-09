`timescale 1ns / 1ps
// ============================================================

module riscv_soc(
    input  clk,
    input  rst,
    input  uart_rx,
    output uart_tx,
    output [3:0] debug_led,

    // Seven-segment display
    output [6:0] seg,
    output [3:0] an
);

    // System clock: 75 MHz from the 100 MHz board oscillator (MMCM) in
    // synthesis; pass-through (100 MHz) in simulation. SoC is held in reset
    // until the MMCM is locked.  100 MHz x 9 = 900 MHz VCO / 12 = 75 MHz.
`ifdef SYNTHESIS
    localparam CLK_HZ = 75_000_000;
    wire clk_fb, clk_fb_buf, clk_mmcm, clk_sys, mmcm_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(10.000), .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(9.000), .CLKFBOUT_PHASE(0.000),
        .CLKOUT0_DIVIDE_F(12.000), .CLKOUT0_DUTY_CYCLE(0.500), .CLKOUT0_PHASE(0.000),
        .REF_JITTER1(0.010), .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(clk), .CLKFBIN(clk_fb_buf), .CLKFBOUT(clk_fb),
        .CLKOUT0(clk_mmcm), .LOCKED(mmcm_locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    BUFG u_fb_bufg  (.I(clk_fb),   .O(clk_fb_buf));
    BUFG u_sys_bufg (.I(clk_mmcm), .O(clk_sys));
    wire rst_i = rst | ~mmcm_locked;
`else
    localparam CLK_HZ = 100_000_000;
    wire clk_sys = clk;
    wire rst_i   = rst;
`endif

    // ---- MMIO bus (CPU → controller) ----
    wire        cpu_mmio_req, cpu_mmio_wr;
    wire [31:0] cpu_mmio_addr, cpu_mmio_wdata, cpu_mmio_rdata;
    wire        cpu_mmio_ready;

    // ---- DCT <-> arbiter ----
    wire [31:0] dct_bram_addr, dct_bram_wdata, dct_bram_rdata;
    wire        dct_bram_we, dct_bram_req;
    // ---- CNN <-> arbiter ----
    wire [31:0] cnn_bram_addr, cnn_bram_wdata, cnn_bram_rdata;
    wire        cnn_bram_we, cnn_bram_req;
    // Weight ROM (read-only, separate BRAM)
    wire [31:0] cnn_wt_addr, cnn_wt_rdata;
    wire        cnn_wt_req;
    wire [3:0] cnn_class_w;
    wire       cnn_done_w;
    // ---- Arbiter mux: CPU vs (DCT | CNN) ----
    // Simple two-level: CPU > DCT > CNN
    wire        acc_req   = dct_bram_req  | cnn_bram_req;
    wire        acc_we    = dct_bram_req  ? dct_bram_we   : cnn_bram_we;
    wire [31:0] acc_addr  = dct_bram_req  ? dct_bram_addr : cnn_bram_addr;
    wire [31:0] acc_wdata = dct_bram_req  ? dct_bram_wdata: cnn_bram_wdata;
    wire [31:0] acc_rdata;
    wire        acc_grant;
    assign dct_bram_rdata = acc_rdata;
    assign cnn_bram_rdata = acc_rdata;

    // ---- MMIO peripheral wires ----
    wire        dct_req_w, dct_we_w, cnn_req_w, cnn_we_w, uart_req_w, uart_we_w;
    wire [7:0]  dct_addr_w, cnn_addr_w, uart_addr_w;
    wire [31:0] dct_wdata_w, cnn_wdata_w, uart_wdata_w;
    wire [31:0] dct_rdata_w, cnn_rdata_w, uart_rdata_w;
    wire        dct_ready_w, cnn_ready_w, uart_ready_w;

    // ---- Frame controller wires (CPU-facing MMIO port) ----
    wire        frame_req_w, frame_we_w;
    wire [7:0]  frame_addr_w;
    wire [31:0] frame_wdata_w, frame_rdata_w;
    wire        frame_ready_w;

    // ---- Frame controller master port toward DCT/CNN ----
    wire        dctm_req_w, dctm_we_w, cnnm_req_w, cnnm_we_w;
    wire [7:0]  dctm_addr_w, cnnm_addr_w;
    wire [31:0] dctm_wdata_w, cnnm_wdata_w;
    wire        frame_active_w;

    // While the frame controller is active it becomes the SOLE master of
    // DCT's and CNN's register interfaces; otherwise the CPU (through
    // mmio_controller) drives them exactly as before.
    wire        dct_req_final   = frame_active_w ? dctm_req_w   : dct_req_w;
    wire        dct_we_final    = frame_active_w ? dctm_we_w    : dct_we_w;
    wire [7:0]  dct_addr_final  = frame_active_w ? dctm_addr_w  : dct_addr_w;
    wire [31:0] dct_wdata_final = frame_active_w ? dctm_wdata_w : dct_wdata_w;

    wire        cnn_req_final   = frame_active_w ? cnnm_req_w   : cnn_req_w;
    wire        cnn_we_final    = frame_active_w ? cnnm_we_w    : cnn_we_w;
    wire [7:0]  cnn_addr_final  = frame_active_w ? cnnm_addr_w  : cnn_addr_w;
    wire [31:0] cnn_wdata_final = frame_active_w ? cnnm_wdata_w : cnn_wdata_w;
    wire [31:0] gpio_in  = 32'b0;  // tie unused GPIO in
    wire [31:0] gpio_out;
    assign debug_led = gpio_out[3:0];
    
    // In riscv_soc.v, replace direct CPU→MMIO connection with:

// ── AXI4-Lite wires between CPU and bridge ──
wire [31:0] axi_awaddr;  wire axi_awvalid; wire axi_awready;
wire [31:0] axi_wdata;   wire [3:0] axi_wstrb;
wire        axi_wvalid;  wire axi_wready;
wire [1:0]  axi_bresp;   wire axi_bvalid;  wire axi_bready;
wire [31:0] axi_araddr;  wire axi_arvalid; wire axi_arready;
wire [31:0] axi_rdata;   wire [1:0] axi_rresp;
wire        axi_rvalid;  wire axi_rready;

// ── Internal MMIO wires (bridge → mmio_controller) ──
wire        bridge_mmio_req, bridge_mmio_wr;
wire [31:0] bridge_mmio_addr, bridge_mmio_wdata;

// New wires for DMA
wire        dma_req_w, dma_we_w;
wire [31:0] dma_addr_w, dma_wdata_w, dma_rdata_w;
wire        dma_ready_w;

// AXI4-Lite bridge instance
axi4lite_to_mmio AXI_BRIDGE (
    .aclk       (clk_sys),
    .aresetn    (!rst_i),         // AXI uses active-low reset
    // Write Address
    .s_awaddr   (axi_awaddr),  .s_awvalid (axi_awvalid),
    .s_awready  (axi_awready),
    // Write Data
    .s_wdata    (axi_wdata),   .s_wstrb   (axi_wstrb),
    .s_wvalid   (axi_wvalid),  .s_wready  (axi_wready),
    // Write Response
    .s_bresp    (axi_bresp),   .s_bvalid  (axi_bvalid),
    .s_bready   (axi_bready),
    // Read Address
    .s_araddr   (axi_araddr),  .s_arvalid (axi_arvalid),
    .s_arready  (axi_arready),
    // Read Data
    .s_rdata    (axi_rdata),   .s_rresp   (axi_rresp),
    .s_rvalid   (axi_rvalid),  .s_rready  (axi_rready),
    // To MMIO controller
    .mmio_request (bridge_mmio_req),
    .mmio_write   (bridge_mmio_wr),
    .mmio_addr    (bridge_mmio_addr),
    .mmio_wdata   (bridge_mmio_wdata),
    .mmio_rdata   (cpu_mmio_rdata),
    .mmio_ready   (cpu_mmio_ready)
);

    // ---- RISC-V Core ----
    riscv_core CORE (
        .clk(clk_sys), .rst(rst_i),
        .mmio_request   (cpu_mmio_req),
        .mmio_write_out (cpu_mmio_wr),
        .mmio_addr_out  (cpu_mmio_addr),
        .mmio_wdata_out (cpu_mmio_wdata),
        .mmio_rdata_in  (cpu_mmio_rdata),
        .mmio_ready_in  (cpu_mmio_ready)
    );

    // ---- MMIO Controller ----
    mmio_controller MMIO (
        .clk(clk_sys), .rst(rst_i),
        .mmio_request(cpu_mmio_req), .mmio_write(cpu_mmio_wr),
        .mmio_addr(cpu_mmio_addr),   .mmio_wdata(cpu_mmio_wdata),
        .mmio_rdata(cpu_mmio_rdata), .mmio_ready(cpu_mmio_ready),
        .dct_req(dct_req_w),   .dct_we(dct_we_w),
        .dct_addr(dct_addr_w), .dct_wdata(dct_wdata_w),
        .dct_rdata(dct_rdata_w), .dct_ready(dct_ready_w),
        .cnn_req(cnn_req_w),   .cnn_we(cnn_we_w),
        .cnn_addr(cnn_addr_w), .cnn_wdata(cnn_wdata_w),
        .cnn_rdata(cnn_rdata_w), .cnn_ready(cnn_ready_w),
        .uart_req(uart_req_w), .uart_we(uart_we_w),
        .uart_addr(uart_addr_w), .uart_wdata(uart_wdata_w),
        .uart_rdata(uart_rdata_w), .uart_ready(uart_ready_w),
        .gpio_in(gpio_in), .gpio_out(gpio_out),
        .dma_req  (dma_req_w),   .dma_we  (dma_we_w),
    .dma_addr (dma_addr_w),  .dma_wdata(dma_wdata_w),
    .dma_rdata(dma_rdata_w), .dma_ready(dma_ready_w),
        .frame_req(frame_req_w),   .frame_we(frame_we_w),
        .frame_addr(frame_addr_w), .frame_wdata(frame_wdata_w),
        .frame_rdata(frame_rdata_w), .frame_ready(frame_ready_w)
    );

    // ---- Frame Controller (4x4-grid DCT/CNN orchestrator) ----
    frame_controller FRAME (
        .clk(clk_sys), .rst(rst_i),
        .req(frame_req_w), .we(frame_we_w),
        .addr(frame_addr_w), .wdata(frame_wdata_w),
        .rdata(frame_rdata_w), .ready(frame_ready_w),
        .dctm_req(dctm_req_w), .dctm_we(dctm_we_w),
        .dctm_addr(dctm_addr_w), .dctm_wdata(dctm_wdata_w),
        .dctm_rdata(dct_rdata_w),
        .cnnm_req(cnnm_req_w), .cnnm_we(cnnm_we_w),
        .cnnm_addr(cnnm_addr_w), .cnnm_wdata(cnnm_wdata_w),
        .cnnm_rdata(cnn_rdata_w),
        .frame_active(frame_active_w)
    );

    // ---- UART ----
    uart_peripheral #(.CLK_FREQ(CLK_HZ),.BAUD_RATE(115200)) UART (
        .clk(clk_sys), .rst(rst_i),
        .req(uart_req_w), .we(uart_we_w),
        .addr(uart_addr_w), .wdata(uart_wdata_w),
        .rdata(uart_rdata_w), .ready(uart_ready_w),
        .uart_rx_pin(uart_rx), .uart_tx_pin(uart_tx)
    );

    // ---- DCT Accelerator ----
    dct_accelerator DCT (
        .clk(clk_sys), .rst(rst_i),
        .req(dct_req_final), .we(dct_we_final),
        .addr(dct_addr_final), .wdata(dct_wdata_final),
        .rdata(dct_rdata_w), .ready(dct_ready_w),
        .bram_addr(dct_bram_addr), .bram_wdata(dct_bram_wdata),
        .bram_we(dct_bram_we),     .bram_rdata(dct_bram_rdata),
        .bram_req(dct_bram_req)
    );

    // ---- CNN Accelerator ----
    cnn_accelerator CNN (
        .clk(clk_sys), .rst(rst_i),
        .req(cnn_req_final), .we(cnn_we_final),
        .addr(cnn_addr_final), .wdata(cnn_wdata_final),
        .rdata(cnn_rdata_w), .ready(cnn_ready_w),

        .bram_addr(cnn_bram_addr),
        .bram_wdata(cnn_bram_wdata),
        .bram_we(cnn_bram_we),
        .bram_rdata(cnn_bram_rdata),
        .bram_req(cnn_bram_req),

        .wt_addr(cnn_wt_addr),
        .wt_rdata(cnn_wt_rdata),
        .wt_req(cnn_wt_req),

        .class_out(cnn_class_w),
        .done_out(cnn_done_w)
    );

    // ---- Seven-Segment Display ----
    seg7_display DISPLAY (
        .clk(clk_sys),
        .rst(rst_i),
        .digit(cnn_class_w),
        .load(cnn_done_w),
        .seg(seg),
        .an(an)
    );

    // ---- Shared BRAM (activation / data memory) ----
    bram_arbiter #(.DEPTH(4096)) SHARED_BRAM (
        .clk(clk_sys), .rst(rst_i),
        .cpu_req  (dma_req_w),    // ← was 1'b0
    .cpu_we   (dma_we_w),     // ← was 1'b0
    .cpu_addr (dma_addr_w),   // ← was 32'b0
    .cpu_wdata(dma_wdata_w),  // ← was 32'b0
    .cpu_rdata(dma_rdata_w),
        .acc_req(acc_req), .acc_we(acc_we),
        .acc_addr(acc_addr), .acc_wdata(acc_wdata),
        .acc_rdata(acc_rdata), .acc_grant(acc_grant)
    );

    // ---- Weight ROM (initialised from file) ----
    // In real synthesis this becomes a Xilinx Block RAM IP with .coe file
    //
    // Address map (word-addressed, dense/non-overlapping, generated by
    // gen_weight_rom.py from the real int8 quantized LeNet-5 tensors --
    // see weight_addr_map.vh for the per-layer base addresses):
    //   conv1_w  0        (150 words)   conv1_b  150     (6 words)
    //   conv2_w  156      (2400 words)  conv2_b  2556    (16 words)
    //   fc1_w    2572     (48000 words) fc1_b    50572   (120 words)
    //   fc2_w    50692    (10080 words) fc2_b    60772   (84 words)
    //   fc3_w    60856    (840 words)   fc3_b    61696   (10 words)
    //   total used: 61706 words -> depth widened to 65536 (16-bit addr)
    //
    // Each weight/bias is a signed int8 value, sign-extended into the
    // low 16 bits of the 32-bit ROM word (bits [31:16] are always 0),
    // matching the existing `$signed(wt_rdata[15:0])` usage in
    // cnn_accelerator.
    (* ram_style = "block" *) reg [31:0] weight_rom [0:65535];
    reg [31:0] cnn_wt_rdata_r;
    initial $readmemh("lenet5_weights.hex", weight_rom);

    always @(posedge clk_sys)
        cnn_wt_rdata_r <= weight_rom[cnn_wt_addr[15:0]];

    assign cnn_wt_rdata = cnn_wt_rdata_r;

     // ---- DMA Ready (BRAM responds in 1 cycle) ----
    assign dma_ready_w = dma_req_w;
    
endmodule
