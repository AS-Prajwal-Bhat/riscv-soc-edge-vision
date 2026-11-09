`timescale 1ns / 1ps

module seg7_display #(
    parameter SEG_ACTIVE_LOW = 1   // Blackboard segments are active-low
)(
    input        clk,
    input        rst,
    input  [3:0] digit,
    input        load,
    output [6:0] seg,              // {g,f,e,d,c,b,a}
    output [3:0] an                // Active-low anodes
);

    reg [3:0] val;
    reg       valid;

    // Capture and hold the predicted digit
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            val   <= 4'd0;
            valid <= 1'b0;
        end
        else if (load) begin
            val   <= digit;
            valid <= 1'b1;
        end
    end

    // Seven-segment decoder
    // Internal patterns are active-high: {g,f,e,d,c,b,a}
    reg [6:0] s;

    always @(*) begin
        case (val)
            4'd0: s = 7'b0111111;
            4'd1: s = 7'b0000110;
            4'd2: s = 7'b1011011;
            4'd3: s = 7'b1001111;
            4'd4: s = 7'b1100110;
            4'd5: s = 7'b1101101;
            4'd6: s = 7'b1111101;
            4'd7: s = 7'b0000111;
            4'd8: s = 7'b1111111;
            4'd9: s = 7'b1101111;
            default: s = 7'b1000000;  // Display '-'
        endcase

        // Keep display blank until first prediction
        if (!valid)
            s = 7'b0000000;
    end

    // Blackboard segment cathodes are active-low
    assign seg = SEG_ACTIVE_LOW ? ~s : s;

    // Enable only rightmost digit (AN0)
    assign an = valid ? 4'b1110 : 4'b1111;

endmodule