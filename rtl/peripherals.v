`timescale 1ns / 1ps
module uart_tx #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input        clk, rst,
    input        start,
    input  [7:0] data,
    output reg   busy,
    output reg   tx
);
    localparam DIVISOR = CLK_FREQ / BAUD_RATE; // 868
    reg [15:0] cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shift; // {stop, data[7:0], start_bit}

    localparam IDLE=0, SEND=1;
    reg state;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE; tx<=1; busy<=0; cnt<=0; bit_idx<=0;
        end else case (state)
            IDLE: begin
                tx<=1; busy<=0;
                if (start) begin
                    shift  <= {1'b1, data, 1'b0}; // stop + 8bits + start
                    cnt    <= 0; bit_idx <= 0;
                    busy   <= 1; state  <= SEND;
                end
            end
            SEND: begin
                if (cnt < DIVISOR-1) begin
                    cnt <= cnt + 1;
                end else begin
                    cnt  <= 0;
                    tx   <= shift[bit_idx];
                    if (bit_idx == 9) begin state<=IDLE; end
                    else bit_idx <= bit_idx + 1;
                end
            end
        endcase
    end
endmodule

// ============================================================================
// 16. UART RECEIVER
// ============================================================================
module uart_rx #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input        clk, rst,
    input        rx,
    output reg   valid,
    output reg [7:0] data
);
    localparam DIVISOR = CLK_FREQ / BAUD_RATE;
    reg [15:0] cnt;
    reg [3:0]  bit_idx;
    reg [7:0]  shift;
    reg [2:0]  rx_sync;
    wire       rx_s = rx_sync[2];

    localparam IDLE=0, START=1, RECV=2, STOP=3;
    reg [1:0] state;

   always @(posedge clk or posedge rst)
begin
    if(rst)
        rx_sync <= 3'b111;
    else
        rx_sync <= {rx_sync[1:0],rx};
end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
    state   <= IDLE;
    valid   <= 0;
    cnt     <= 0;
    bit_idx <= 0;
    shift   <= 8'b0;
    data    <= 8'b0;
end else begin
            valid<=0;
            case (state)
                IDLE:  if (!rx_s) begin cnt<=0; state<=START; end
                START: if (cnt < DIVISOR/2-1) cnt<=cnt+1;
                       else begin cnt<=0; bit_idx<=0; state<=RECV; end
                RECV:  if (cnt < DIVISOR-1) cnt<=cnt+1;
                       else begin
                           cnt<=0; shift[bit_idx]<=rx_s;
                           if (bit_idx==7) state<=STOP;
                           else bit_idx<=bit_idx+1;
                       end
                 STOP:
begin
    if(cnt < DIVISOR-1)
        cnt <= cnt + 1;
    else begin
        cnt <= 0;

        if(rx_s) begin
            data <= shift;
            valid <= 1;
        end

        state <= IDLE;
    end
end
            endcase
        end
    end
endmodule

// ============================================================================
// 17. UART TOP WRAPPER  (register-mapped: addr 0x00=data, 0x04=status)
//     Memory map (MMIO 0x40000200):
//       0x00  TX/RX data byte
//       0x04  Status: [1]=rx_valid, [0]=tx_busy
// ============================================================================
module uart_peripheral #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115200
)(
    input        clk, rst,
    input        req, we,
    input  [7:0] addr,
    input  [31:0] wdata,
    output reg [31:0] rdata,
    output reg   ready,
    input        uart_rx_pin,
    output       uart_tx_pin
);
    reg        tx_start;
    reg  [7:0] tx_byte;
    wire       tx_busy;
    wire       rx_valid;
    wire [7:0] rx_byte;
    reg  [7:0] rx_buf;
    reg        rx_buf_valid;

    uart_tx #(.CLK_FREQ(CLK_FREQ),.BAUD_RATE(BAUD_RATE)) UTX (
        .clk(clk),.rst(rst),.start(tx_start),.data(tx_byte),
        .busy(tx_busy),.tx(uart_tx_pin)
    );
    uart_rx #(.CLK_FREQ(CLK_FREQ),.BAUD_RATE(BAUD_RATE)) URX (
        .clk(clk),.rst(rst),.rx(uart_rx_pin),.valid(rx_valid),.data(rx_byte)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_start<=0; ready<=0; rx_buf<=0; rx_buf_valid<=0;
        end else begin
            tx_start<=0; ready<=0;
            if (rx_valid) begin rx_buf<=rx_byte; rx_buf_valid<=1; end
            if (req) begin
                ready<=1;
                if (we && addr[3:0]==4'h0) begin
                    tx_byte<=wdata[7:0]; tx_start<=1;
                end else if (!we) begin
                    case (addr[3:0])
                        4'h0: begin rdata<={24'b0,rx_buf}; rx_buf_valid<=0; end
                        4'h4: rdata<={30'b0, rx_buf_valid, tx_busy};
                        default: rdata<=0;
                    endcase
                end
            end
        end
    end
endmodule

// ============================================================
// AXI4-Lite to Internal MMIO Bridge
// Sits between CPU and mmio_controller
// Converts AXI4-Lite protocol to your existing req/ready bus
// ============================================================
// ============================================================
// AXI4-Lite to Internal MMIO Bridge (Strict 0->1 Handshake)
// Sits between CPU and mmio_controller
// ============================================================
module axi4lite_to_mmio (
    input  wire        aclk,
    input  wire        aresetn,    // AXI uses active-low reset

    // ── AXI4-Lite Slave Write Address Channel ──
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output reg         s_awready,

    // ── AXI4-Lite Slave Write Data Channel ──
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,    
    input  wire        s_wvalid,
    output reg         s_wready,

    // ── AXI4-Lite Slave Write Response Channel ──
    output reg  [1:0]  s_bresp,    
    output reg         s_bvalid,
    input  wire        s_bready,

    // ── AXI4-Lite Slave Read Address Channel ──
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output reg         s_arready,

    // ── AXI4-Lite Slave Read Data Channel ──
    output reg  [31:0] s_rdata,
    output reg  [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    // ── Internal MMIO bus (to your existing mmio_controller) ──
    output reg         mmio_request,
    output reg         mmio_write,
    output reg  [31:0] mmio_addr,
    output reg  [31:0] mmio_wdata,
    input  wire [31:0] mmio_rdata,
    input  wire        mmio_ready
);

    // Expanded State Machine for 0 -> 1 transition detection
    localparam IDLE         = 3'd0;
    localparam W_WAIT_DROP  = 3'd1;  // wait for ready to clear from previous transaction
    localparam W_WAIT_RISE  = 3'd2;  // wait for ready to assert for current transaction
    localparam R_WAIT_DROP  = 3'd3;  // wait for ready to clear from previous transaction
    localparam R_WAIT_RISE  = 3'd4;  // wait for ready to assert for current transaction

    reg [2:0]  state;
    reg [31:0] aw_addr_latch;   
    reg [31:0] ar_addr_latch;   

    always @(posedge aclk) begin
        if (!aresetn) begin
            state        <= IDLE;
            s_awready    <= 1'b0;
            s_wready     <= 1'b0;
            s_bvalid     <= 1'b0;
            s_bresp      <= 2'b00;
            s_arready    <= 1'b0;
            s_rvalid     <= 1'b0;
            s_rresp      <= 2'b00;
            s_rdata      <= 32'b0;
            mmio_request <= 1'b0;
            mmio_write   <= 1'b0;
            mmio_addr    <= 32'b0;
            mmio_wdata   <= 32'b0;
        end else begin
            // Default: deassert strobes
            s_awready    <= 1'b0;
            s_wready     <= 1'b0;
            s_arready    <= 1'b0;

            case (state)
                // ── IDLE: wait for read or write address ──
                IDLE: begin
                    if (s_bvalid && s_bready) s_bvalid <= 1'b0;
                    if (s_rvalid && s_rready) s_rvalid <= 1'b0;

                    mmio_request <= 1'b0; // Ensure request is low when idle

                    // Write request
                    if (s_awvalid && s_wvalid) begin
                        s_awready    <= 1'b1;        
                        s_wready     <= 1'b1;        
                        aw_addr_latch <= s_awaddr;
                        mmio_request <= 1'b1;
                        mmio_write   <= 1'b1;
                        mmio_addr    <= s_awaddr;
                        mmio_wdata   <= s_wdata;
                        state        <= W_WAIT_DROP;
                    end
                    // Read request 
                    else if (s_arvalid) begin
                        s_arready    <= 1'b1;        
                        ar_addr_latch <= s_araddr;
                        mmio_request <= 1'b1;
                        mmio_write   <= 1'b0;
                        mmio_addr    <= s_araddr;
                        state        <= R_WAIT_DROP;
                    end
                end

                // ── Write Phase 1: Wait for stale ready to drop ──
                W_WAIT_DROP: begin
                    mmio_request <= 1'b1;  
                    mmio_write   <= 1'b1;
                    mmio_addr    <= aw_addr_latch;
                    if (mmio_ready == 1'b0) begin
                        state <= W_WAIT_RISE;
                    end
                end

                // ── Write Phase 2: Wait for genuine ready to assert ──
                W_WAIT_RISE: begin
                    mmio_request <= 1'b1;  
                    mmio_write   <= 1'b1;
                    mmio_addr    <= aw_addr_latch;
                    if (mmio_ready == 1'b1) begin
                        s_bvalid     <= 1'b1;
                        s_bresp      <= 2'b00;  
                        mmio_request <= 1'b0;
                        state        <= IDLE;
                    end
                end

                // ── Read Phase 1: Wait for stale ready to drop ──
                R_WAIT_DROP: begin
                    mmio_request <= 1'b1;  
                    mmio_write   <= 1'b0;
                    mmio_addr    <= ar_addr_latch;
                    if (mmio_ready == 1'b0) begin
                        state <= R_WAIT_RISE;
                    end
                end

                // ── Read Phase 2: Wait for genuine ready to assert ──
                R_WAIT_RISE: begin
                    mmio_request <= 1'b1;  
                    mmio_write   <= 1'b0;
                    mmio_addr    <= ar_addr_latch;
                    if (mmio_ready == 1'b1) begin
                        s_rdata      <= mmio_rdata;
                        s_rresp      <= 2'b00;  
                        s_rvalid     <= 1'b1;
                        mmio_request <= 1'b0;
                        state        <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

module mmio_controller(
    input         clk, rst,
    input         mmio_request,
    input         mmio_write,
    input  [31:0] mmio_addr,
    input  [31:0] mmio_wdata,
    output reg [31:0] mmio_rdata,
    output reg    mmio_ready,
    
    // DCT
    output reg        dct_req, dct_we,
    output reg [7:0]  dct_addr,
    output reg [31:0] dct_wdata,
    input  [31:0]     dct_rdata,
    input             dct_ready,

    // CNN
    output reg        cnn_req, cnn_we,
    output reg [7:0]  cnn_addr,
    output reg [31:0] cnn_wdata,
    input  [31:0]     cnn_rdata,
    input             cnn_ready,

    // UART
    output reg        uart_req, uart_we,
    output reg [7:0]  uart_addr,
    output reg [31:0] uart_wdata,
    input  [31:0]     uart_rdata,
    input             uart_ready,

    // GPIO
    input  [31:0]     gpio_in,
    output reg [31:0] gpio_out,
    
    output reg        dma_req, dma_we,
output reg [31:0] dma_addr,
output reg [31:0] dma_wdata,
input  [31:0]     dma_rdata,
input             dma_ready,

    // Frame controller (4x4-grid DCT/CNN orchestrator)
    output reg        frame_req, frame_we,
    output reg [7:0]  frame_addr,
    output reg [31:0] frame_wdata,
    input  [31:0]     frame_rdata,
    input             frame_ready
);
    // Peripheral-select nibble moved from mmio_addr[11:8] to mmio_addr[15:12]
    // so each peripheral gets a full 4KB slice (0x40000000, 0x40001000, ...)
    // instead of 256 bytes. The old [11:8]-based decode OVERLAPPED with the
    // DMA word-offset field mmio_addr[9:0] on bits 9:8 -- sel_dma required
    // those bits to be 0, silently clamping firmware's reachable shared-BRAM
    // range to just 64 words (256 bytes) instead of the intended 1024 words.
    wire sel_dct   = (mmio_addr[31:16]==16'h4000) && (mmio_addr[15:12]==4'h0);
    wire sel_cnn   = (mmio_addr[31:16]==16'h4000) && (mmio_addr[15:12]==4'h1);
    wire sel_uart  = (mmio_addr[31:16]==16'h4000) && (mmio_addr[15:12]==4'h2);
    wire sel_gpio  = (mmio_addr[31:16]==16'h4000) && (mmio_addr[15:12]==4'h3);
    wire sel_dma   = (mmio_addr[31:16]==16'h4000) && (mmio_addr[15:12]==4'h4);
    wire sel_frame = (mmio_addr[31:16]==16'h4000) && (mmio_addr[15:12]==4'h5);

    // FIX: guards against a spurious same-cycle "ready" read. mmio_controller
    // previously sampled dct_ready/cnn_ready/uart_ready/frame_ready on the
    // SAME cycle it first asserts req to that peripheral -- but that peripheral
    // hasn't seen req yet (req only becomes visible to it starting the NEXT
    // cycle), so this captures whatever ready state happens to be LEFT OVER
    // from a completely different, unrelated PRIOR transaction. If that prior
    // transaction's ready_r tail hadn't fully decayed yet, mmio_ready could
    // read 1 on the very first cycle of a brand-new, different transaction,
    // letting the CPU capture stale mmio_rdata instead of genuinely waiting.
    // Observed causing receive_image()'s uart_status() poll to see a
    // falsely-already-set rx_valid bit and race through all 1024 bytes in
    // ~1us instead of the ~106ms real UART reception requires.
    // Forcing mmio_ready low for the first cycle of every request guarantees
    // the target peripheral has had at least one full cycle to genuinely see
    // and begin processing THIS request before its ready is ever trusted.
reg mmio_request_d;
    always @(posedge clk or posedge rst) begin
        if (rst) mmio_request_d <= 1'b0;
        else     mmio_request_d <= mmio_request;
    end
    wire mmio_req_first_cycle = mmio_request && !mmio_request_d;
    always @(posedge clk or posedge rst) begin

       if (rst) begin
    dct_req    <= 0;
    cnn_req    <= 0;
    uart_req   <= 0;

    dct_we     <= 0;
    cnn_we     <= 0;
    uart_we    <= 0;

    dct_addr   <= 0;
    cnn_addr   <= 0;
    uart_addr  <= 0;

    dct_wdata  <= 0;
    cnn_wdata  <= 0;
    uart_wdata <= 0;
    {dct_req, cnn_req, uart_req, dma_req, frame_req} <= 5'b0;
    mmio_rdata <= 0;
    mmio_ready <= 0;

    gpio_out   <= 0;
end else begin
            dct_req<=0; cnn_req<=0; uart_req<=0;dma_req<=0; frame_req<=0; mmio_ready<=0;
            if (mmio_request) begin
                if (sel_dct) begin
                    dct_req<=1; dct_we<=mmio_write;
                    dct_addr<=mmio_addr[7:0]; dct_wdata<=mmio_wdata;
                    mmio_rdata<=dct_rdata; mmio_ready<= mmio_req_first_cycle ? 1'b0 : dct_ready;
                end else if (sel_cnn) begin
                    cnn_req<=1; cnn_we<=mmio_write;
                    cnn_addr<=mmio_addr[7:0]; cnn_wdata<=mmio_wdata;
                    mmio_rdata<=cnn_rdata; mmio_ready<= mmio_req_first_cycle ? 1'b0 : cnn_ready;
                end else if (sel_uart) begin
                    uart_req<=1; uart_we<=mmio_write;
                    uart_addr<=mmio_addr[7:0]; uart_wdata<=mmio_wdata;
                    mmio_rdata<=uart_rdata; mmio_ready<= mmio_req_first_cycle ? 1'b0 : uart_ready;
                end else if (sel_gpio) begin
                    if (mmio_write) gpio_out<=mmio_wdata;
                    else mmio_rdata<=gpio_in;
                    mmio_ready<=1;
                end else if (sel_dma) begin

    dma_req   <= 1;
    dma_we    <= mmio_write;
    dma_addr  <= {20'b0, mmio_addr[11:0]}; // byte address from offset (>>2'd in bram_arbiter)
    dma_wdata <= mmio_wdata;
    mmio_rdata <= dma_rdata;
    mmio_ready <= dma_ready;
end else if (sel_frame) begin
                    frame_req<=1; frame_we<=mmio_write;
                    frame_addr<=mmio_addr[7:0]; frame_wdata<=mmio_wdata;
                    mmio_rdata<=frame_rdata; mmio_ready<= mmio_req_first_cycle ? 1'b0 : frame_ready;
                end
                else begin
                    mmio_rdata<=32'hDEAD_BEEF; mmio_ready<=1;
                end
            end
        end
    end
    
endmodule