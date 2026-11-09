// ============================================================================
// TESTBENCH - riscv_soc
// Simulates: PC sends 1024 bytes (32x32 image) over UART
//            → SoC → DCT → CNN → UART classification result
// Target: Xilinx Vivado 2024.1 XSim
// ============================================================================
`timescale 1ns / 1ps

module tb_riscv_soc;

    // ---- Clock & Reset ----
    reg clk;
    reg rst;

    // ---- UART ----
    wire uart_tx;        // SoC → PC
    reg  uart_rx;        // PC → SoC
    wire [3:0] debug_led;
    

    // ---- DUT (Device Under Test) ----
    riscv_soc DUT (
        .clk       (clk),
        .rst       (rst),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
        .debug_led (debug_led)
    );

    // ---- Clock: 100 MHz = 10 ns period ----
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- UART Parameters ----
    // 115200 baud at 100 MHz → 868 clock cycles per bit
    localparam BAUD_PERIOD = 8680; // nanoseconds (868 cycles × 10ns)

    // ---- Task: Send one byte over UART (PC → SoC) ----
    task uart_send_byte;
        input [7:0] data;
        integer i;
        begin
            // Start bit (LOW)
            uart_rx = 0;
            #BAUD_PERIOD;

            // 8 data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];
                #BAUD_PERIOD;
            end

            // Stop bit (HIGH)
            uart_rx = 1;
            #BAUD_PERIOD;
            #(BAUD_PERIOD*2);
        end
    endtask

    // ---- Task: Receive one byte from SoC over UART ----
    reg [7:0] received_byte = 8'b00000000;
    task uart_receive_byte;
        integer i;
        begin
            
            

            // Wait half a bit period to sample in middle
            #(BAUD_PERIOD/2);

            // Sample 8 data bits
            for (i = 0; i < 8; i = i + 1) begin
                #BAUD_PERIOD;
                received_byte[i] = uart_tx;
            end

            // Wait for stop bit
            #BAUD_PERIOD;
        end
    endtask

 reg [7:0] test_image [0:1023];
  integer i, r, c ;
  initial begin
    $readmemh("digit5_32x32.hex", test_image);
    $display("PIXEL 0   = %0d", test_image[0]);
    $display("PIXEL 100 = %0d", test_image[100]);
    $display("PIXEL 500 = %0d", test_image[500]);

    $finish;
    $display("[TB] Loaded digit5_32x32.hex (32x32 = 1024 pixels)");
    $display("[TB] Preview of image (thresholded): #=bright, .=dark");
    for (r = 0; r < 32; r = r + 1) begin
      $write("  ");
      for (c = 0; c < 32; c = c + 1) begin
        if (test_image[r*32 + c] > 8'd128) $write("#");
        else                                $write(".");
      end
      $write("\n");
    end
    /*reg [7:0] test_image [0:1023];
    integer i, r, c;
    initial begin
        // Change from digit hex to your CIFAR-10 image hex file
        $readmemh("dog_32x32.hex", test_image);
        $display("[TB] Loaded cifar10_test_image.hex (32x32 = 1024 pixels)");
        $display("[TB] Preview of grayscale image:");
        for (r = 0; r < 32; r = r + 1) begin
            $write("  ");
            for (c = 0; c < 32; c = c + 1) begin
                if (test_image[r*32 + c] > 8'd180)      $write("#");
                else if (test_image[r*32 + c] > 8'd100) $write("+");
                else if (test_image[r*32 + c] > 8'd40)  $write(".");
                else                                    $write(" ");
            end
            $write("\n");
        end
    
$display("");*/
$display("===== RAW TEST_IMAGE DEBUG =====");

for (i = 0; i < 16; i = i + 1) begin
    $display(
        "test_image[%0d] = HEX:%02h  DEC:%0d",
        i,
        test_image[i],
        test_image[i]
    );
end

$display("================================");
$display("");
end

    // ---- Class names for display ----
    // (just used in $display messages)

    // ---- MAIN TEST SEQUENCE ----
integer j;   // ← add this at module level alongside integer i

initial begin
    $dumpfile("tb_riscv_soc.vcd");
    $dumpvars(0, tb_riscv_soc);
$display("*** MARKER: TESTBENCH RECOMPILED ***");
    uart_rx = 1;
    rst = 1;
    repeat(20) @(posedge clk);
    rst = 0;
    repeat(10) @(posedge clk);

    $display("=================================================");
    $display("  RISC-V SoC Full Pipeline Test");
    $display("  Image -> UART -> DCT -> CNN -> UART -> Result");
    $display("=================================================");

    // Boot delay - let CPU fetch first instruction
    repeat(500) @(posedge clk);

    // ── Step 1: Send 1024 image bytes (32x32) over UART ──
    $display("[TB] Sending 1024 image bytes over UART...");
    for (j = 0; j < 1024; j = j + 1) begin
        uart_send_byte(test_image[j]);
        if (j % 32 == 31)
            $display("[TB] Sent row %0d/32", (j/32)+1);
    end
$display("[TB] All 1024 bytes sent. Waiting for DCT (16 blocks) + CNN...");


    // ── Step 2: Wait for classification result ──
  fork: pipeline_fork
        begin
            @(negedge uart_tx);
            $display("[TB] uart_tx went LOW - SoC is sending result!");
            uart_receive_byte();
            $display("[TB] Classification result: class %0d", received_byte);
            case(received_byte)
                0: $display("[TB] Predicted: 0 (Zero)");
                1: $display("[TB] Predicted: 1 (One)");
                2: $display("[TB] Predicted: 2 (Two)");
                3: $display("[TB] Predicted: 3 (Three)");
                4: $display("[TB] Predicted: 4 (Four)");
                5: $display("[TB] Predicted: 5 (Five)");
                6: $display("[TB] Predicted: 6 (Six)");
                7: $display("[TB] Predicted: 7 (Seven)");
                8: $display("[TB] Predicted: 8 (Eight)");
                9: $display("[TB] Predicted: 9 (Nine)");
                default: $display("[TB] Unexpected: 0x%02h", received_byte);
            endcase
            $display("[TB] PASS - End-to-end pipeline verified!");
            disable pipeline_fork;
        end
        begin
            #200_000_000; // 200ms timeout
            $display("[TB] TIMEOUT - SoC did not respond within 200ms");
            $display("[TB] Check DCT busy and CNN busy signals in waveform");
            disable pipeline_fork;
        end
    join
    // ── Step 2: Wait for classification result ──
    /*fork: pipeline_fork
        begin
            @(negedge uart_tx);
            $display("[TB] uart_tx went LOW - SoC is sending result!");
            uart_receive_byte();
            $display("[TB] Classification result: class %0d", received_byte);
            case(received_byte)
                0: $display("[TB] Predicted: Airplane (Class 0)");
                1: $display("[TB] Predicted: Automobile (Class 1)");
                2: $display("[TB] Predicted: Bird (Class 2)");
                3: $display("[TB] Predicted: Cat (Class 3)");
                4: $display("[TB] Predicted: Deer (Class 4)");
                5: $display("[TB] Predicted: Dog (Class 5)");
                6: $display("[TB] Predicted: Frog (Class 6)");
                7: $display("[TB] Predicted: Horse (Class 7)");
                8: $display("[TB] Predicted: Ship (Class 8)");
                9: $display("[TB] Predicted: Truck (Class 9)");
                default: $display("[TB] Unexpected class ID: 0x%02h", received_byte);
            endcase
            $display("[TB] PASS - End-to-end pipeline verified!");
            disable pipeline_fork;
        end
        begin
            #200_000_000; // 200ms timeout
            $display("[TB] TIMEOUT - SoC did not respond within 200ms");
            disable pipeline_fork;
        end
    join*/
   
    repeat(100) @(posedge clk);
    $display("[TB] Simulation complete");
    $finish;
end



    // ---- Timeout watchdog (prevent infinite simulation) ----
    initial begin
        #1_000_000_000; // 1 second timeout
        $display("[TB] TIMEOUT - simulation took too long");
        $finish;
    end
    
   

// ---- Monitor key signals ----
/*initial begin
    $monitor("[%0t ns] rst=%b led=%b tx=%b rx=%b",
              $time, rst, debug_led, uart_tx, uart_rx);
end
*/

// ============================================================
// DCT BLOCK OUTPUT MONITOR
// ============================================================
always @(posedge clk)begin
if (DUT.DCT.ready) begin

    // Give nonblocking assignments one delta cycle to settle
    #1;

    $display("");
    $display("================================================");
    $display("[TB] DCT BLOCK COMPLETED");
    $display("================================================");

    $display("");
    $display("---------- DCT INPUT blk_in[] ----------");

    for (i = 0; i < 64; i = i + 1) begin
        $display(
            "[DCT IN] blk_in[%0d] = HEX:%02h DEC:%0d",
            i,
            DUT.DCT.blk_in[i],
            DUT.DCT.blk_in[i]
        );
    end

    $display("");
    $display("---------- DCT OUTPUT blk_dct[] ----------");

    for (i = 0; i < 64; i = i + 1) begin
        $display(
            "[DCT OUT] blk_dct[%0d] = %0d",
            i,
            $signed(DUT.DCT.blk_dct[i])
        );
    end

    $display("================================================");
end
end
    
// ============================================================================
// REPLACE your existing one-shot PC-MONITOR initial block in tb_riscv_soc.v
// with this. It samples PC every 2us for the ENTIRE run (UART send takes
// ~106ms by itself, so the old 56.7ms-and-done window never even saw the
// end of the byte transfer, let alone any trigger/compute phase after it).
// Also logs every MMIO write with the target peripheral name decoded, so
// we can see directly whether/when firmware ever writes to 0x40000500
// (frame_controller) vs 0x40000000 (old direct DCT trigger).
// ============================================================================

always @(posedge clk) begin
    if (!rst && DUT.MMIO.mmio_request && DUT.MMIO.mmio_write) begin
        case (DUT.MMIO.mmio_addr[15:12])
            4'h0: $display("[MMIO-WR->DCT]   t=%0t addr=0x%08h wdata=0x%08h", $time, DUT.MMIO.mmio_addr, DUT.MMIO.mmio_wdata);
            4'h1: $display("[MMIO-WR->CNN]   t=%0t addr=0x%08h wdata=0x%08h", $time, DUT.MMIO.mmio_addr, DUT.MMIO.mmio_wdata);
            4'h2: $display("[MMIO-WR->UART]  t=%0t addr=0x%08h wdata=0x%08h", $time, DUT.MMIO.mmio_addr, DUT.MMIO.mmio_wdata);
            4'h3: $display("[MMIO-WR->GPIO]  t=%0t addr=0x%08h wdata=0x%08h", $time, DUT.MMIO.mmio_addr, DUT.MMIO.mmio_wdata);
            4'h4: ; // DMA writes are high-volume (one per received byte) -- suppressed
            4'h5: $display("[MMIO-WR->FRAME] t=%0t addr=0x%08h wdata=0x%08h", $time, DUT.MMIO.mmio_addr, DUT.MMIO.mmio_wdata);
            default: $display("[MMIO-WR->???]   t=%0t addr=0x%08h wdata=0x%08h", $time, DUT.MMIO.mmio_addr, DUT.MMIO.mmio_wdata);
        endcase
    end
end

reg [31:0] pc_prev = 32'hFFFF_FFFF;
integer stuck_count = 0;
always @(posedge clk) begin
    if (!rst) begin
        if (DUT.CORE.PC.pc_out == pc_prev) begin
            stuck_count <= stuck_count + 1;
            // Flag if PC hasn't moved in 2000 consecutive cycles (=20us) --
            // strong signal of a spin loop (e.g. waiting on a condition
            // that never becomes true, like rx_buf_valid never asserting).
            if (stuck_count == 2000)
                $display("[PC-STUCK] t=%0t PC has not changed in 20us, sitting at 0x%08h", $time, pc_prev);
        end else begin
            stuck_count <= 0;
        end
        pc_prev <= DUT.CORE.PC.pc_out;
    end
end

reg [2:0] dct_state_prev;
initial dct_state_prev = 4'hF;

always @(posedge clk) begin
    if (DUT.DCT.state !== dct_state_prev) begin
        $display("[DCT-FSM] t=%0t state %0d->%0d busy=%b ctrl=%h",
                  $time,
                  dct_state_prev, DUT.DCT.state,
                  DUT.DCT.busy, DUT.DCT.ctrl_reg);
        dct_state_prev <= DUT.DCT.state;
    end
end

reg [3:0] cnn_state_prev=4'hF;
always @(posedge clk) begin
    if (DUT.CNN.state !== cnn_state_prev) begin
        $display("[CNN-FSM] t=%0t  state %0d -> %0d  busy=%b done=%b ctrl=%h pix_cnt=%0d",
                  $time, cnn_state_prev, DUT.CNN.state,
                  DUT.CNN.busy, DUT.CNN.done, DUT.CNN.ctrl_reg, DUT.CNN.pix_cnt);
        cnn_state_prev <= DUT.CNN.state;
    end
end

 reg [3:0] frame_state_prev = 4'hF;
always @(posedge clk) begin
    if (DUT.FRAME.state !== frame_state_prev) begin
        $display("[FRAME-FSM] t=%0t  state %0d -> %0d  busy=%b class_reg=%0d",
                  $time, frame_state_prev, DUT.FRAME.state,
                  DUT.FRAME.busy, DUT.FRAME.class_reg);
        frame_state_prev <= DUT.FRAME.state;
    end
end

// Watch every MMIO access the CPU makes specifically to frame_controller's
// register range (0x40005xxx), so we can see exactly what value the CPU
// read for FRAME_STATUS/FRAME_CLASS and exactly when, relative to
// frame_controller's own real state transitions above.
always @(posedge clk) begin
    if (DUT.MMIO.mmio_request && DUT.MMIO.mmio_addr[31:12] == 20'h40005) begin
        $display("[FRAME-MMIO] t=%0t addr=%03h we=%b wdata=%08h | ready=%b rdata=%08h | FRAME.busy=%b FRAME.state=%0d FRAME.class_reg=%0d",
                  $time, DUT.MMIO.mmio_addr[11:0], DUT.MMIO.mmio_write, DUT.MMIO.mmio_wdata,
                  DUT.MMIO.mmio_ready, DUT.MMIO.mmio_rdata,
                  DUT.FRAME.busy, DUT.FRAME.state, DUT.FRAME.class_reg);
    end
end

// ---- Early PC trace: is the CPU genuinely executing near 0xf0 this early,
//      or is this a reset/pipeline-fill artifact? ----
reg [31:0] pc_trace_prev;
integer pc_trace_count;
initial begin pc_trace_prev = 32'hFFFFFFFF; pc_trace_count = 0; end
always @(posedge clk) begin
    if (!rst && DUT.CORE.PC.pc_out !== pc_trace_prev && pc_trace_count < 80) begin
        $display("[PC-TRACE] t=%0t pc=%08h", $time, DUT.CORE.PC.pc_out);
        pc_trace_prev <= DUT.CORE.PC.pc_out;
        pc_trace_count <= pc_trace_count + 1;
    end
end


// ============================================================
// STUCK-PC DETECTOR
// ============================================================

localparam STALL_THRESHOLD = 100;

reg [31:0] pc_prev_val;
reg [31:0] stall_count;
reg        stall_flagged;

initial begin
    pc_prev_val   = 32'hFFFF_FFFF;
    stall_count   = 0;
    stall_flagged = 0;
end

always @(posedge clk) begin
    if (rst) begin
        pc_prev_val   <= 32'hFFFF_FFFF;
        stall_count   <= 0;
        stall_flagged <= 0;
    end else begin
        if (DUT.CORE.PC.pc_out == pc_prev_val) begin
            stall_count <= stall_count + 1;
        end else begin
            stall_count   <= 0;
            stall_flagged <= 0;
            pc_prev_val   <= DUT.CORE.PC.pc_out;
        end

        if (stall_count == STALL_THRESHOLD && !stall_flagged) begin
            stall_flagged <= 1;

            $display("========================================================");
            $display("[STUCK-PC] t=%0t PC FROZEN at 0x%08h",
                     $time, DUT.CORE.PC.pc_out);

            $display("[STUCK-PC] pc_write=%b if_id_write=%b mmio_read_stall=%b",
                     DUT.CORE.pc_write, DUT.CORE.if_id_write,
                     DUT.CORE.mmio_read_stall);

            $display("[STUCK-PC] branch_taken=%b stall_w=%b id_ex_flush=%b",
                     DUT.CORE.branch_taken, DUT.CORE.stall_w,
                     DUT.CORE.id_ex_flush);

            $display("[STUCK-PC] id_instr=0x%08h ex_alu_sel=%h ex_ALUsrc=%b",
                     DUT.CORE.id_instr, DUT.CORE.ex_alu_sel,
                     DUT.CORE.ex_ALUsrc);

            $display("[STUCK-PC] mem_MR=%b mem_MW=%b mem_alu_result=0x%08h",
                     DUT.CORE.mem_MR, DUT.CORE.mem_MW,
                     DUT.CORE.mem_alu_result);

            $display("[STUCK-PC] cpu_mmio_req=%b cpu_mmio_wr=%b addr=0x%08h ready=%b",
                     DUT.cpu_mmio_req, DUT.cpu_mmio_wr,
                     DUT.cpu_mmio_addr, DUT.cpu_mmio_ready);

            $display("[STUCK-PC] uart_rx_pin=%b", uart_rx);
            $display("========================================================");
        end
    end
end


// ============================================================
// FRAME CONTROL MONITOR
// ============================================================

always @(posedge clk) begin
    if (!rst &&
        DUT.MMIO.mmio_request &&
        DUT.MMIO.mmio_write &&
        DUT.MMIO.mmio_ready &&
        DUT.MMIO.mmio_addr[15:0] == 16'h5000 &&
        DUT.MMIO.mmio_wdata[0]) begin

        $display("[FRAME-CTRL-FIRED] t=%0t", $time);
    end
end


// ============================================================
// FRAME FSM MONITOR
// ============================================================

reg [3:0] last_fsm_state;
integer fsm_trace_count;

initial begin
    last_fsm_state = 4'hF;
    fsm_trace_count = 0;
end

always @(posedge clk) begin
    if (!rst &&
        DUT.FRAME.state != last_fsm_state &&
        fsm_trace_count < 500) begin

        $display("[FRAME-FSM] t=%0t state=%0d busy=%b",
                 $time, DUT.FRAME.state, DUT.FRAME.busy);

        last_fsm_state <= DUT.FRAME.state;
        fsm_trace_count <= fsm_trace_count + 1;
    end
end


// ============================================================
// CNN DIAGNOSTIC MONITORS
// ============================================================

integer k;

always @(DUT.CNN.state) begin
    $display("[CNN-FSM] t=%0t state=%0d",
             $time, DUT.CNN.state);
end

always @(posedge DUT.DCT.done) begin
    $display("[DCT] t=%0t block done blk_dct[0]=%0d",
             $time, $signed(DUT.DCT.blk_dct[0]));
end
initial begin
    $display("******** CNN DEBUG INITIAL BLOCK STARTED ********");

    #1000;

    $display("[DEBUG] CNN monitor is ACTIVE at t=%0t", $time);
    $display("[DEBUG] CNN initial state = %0d", DUT.CNN.state);
    $display("[DEBUG] CNN initial done = %b", DUT.CNN.done);

    $display("******** CNN DEBUG INITIAL BLOCK FINISHED ********");
end
always @(posedge clk) begin
    if (!rst && DUT.CNN.done) begin

        $display("========================================");
        $display("[CNN] t=%0t CNN DONE", $time);

        for (k = 0; k < 10; k = k + 1) begin
            $display("[CNN] logit[%0d] = %0d",
                     k, $signed(DUT.CNN.fc_out[k]));
        end

        $display("[CNN] class_reg=%0d FRAME.class_reg=%0d",
                 DUT.CNN.class_reg, DUT.FRAME.class_reg);

        $display("========================================");
    end
end

endmodule
// ============================================================================
// END OF TESTBENCH
// ============================================================================