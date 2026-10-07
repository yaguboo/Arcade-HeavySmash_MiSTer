//============================================================================
//  Heavy Smash -- ioctl byte stream -> SDRAM words, five ROM regions.
//
//  Platform transport: lives in integration/, keeps ioctl_* out of rtl/
//  (root CLAUDE.md section 4).  Byte pair {even, odd} packs one big-endian
//  word exactly like stadium_hero's sh_download.sv (whose ioctl_wait
//  power-up note applies here verbatim -- read sh_download.sv:76-88).
//
//  Region map (word addresses, REUSE_PLAN):
//     index 0  main ROM   base 0x000000  (lt01/lt00 interleaved by the MRA)
//     index 1  tiles      base 0x080000  (mbg-00 file order)
//     index 2  sprites    base 0x180000  (mbg-02 then mbg-01)
//     index 3  oki0       base 0x380000  (mbg-03)
//     index 4  oki1       base 0x3C0000  (mbg-04, descrambled live)
//============================================================================
`default_nettype none

module hs_download (
    input  wire        clk,
    input  wire        rst,

    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    input  wire [15:0] ioctl_index,
    output wire        ioctl_wait,

    output reg  [24:0] dl_addr,
    output reg  [15:0] dl_data,
    output reg         dl_req = 1'b0,
    input  wire        dl_ack,
    output wire        dl_active
);

    // region select from the MRA <rom index>
    function automatic [24:0] base_of(input [15:0] idx);
        base_of = (idx == 16'd0) ? 25'h000000 :
                  (idx == 16'd1) ? 25'h080000 :
                  (idx == 16'd2) ? 25'h180000 :
                  (idx == 16'd3) ? 25'h380000 :
                  (idx == 16'd4) ? 25'h3C0000 : 25'h7FFFFF;
    endfunction

    wire [15:0] idx_r = (ioctl_index > 16'd4) ? 16'hFFFF : ioctl_index;
    wire is_rom = (ioctl_index <= 16'd4);
    wire [24:0] base = base_of(idx_r);

    reg [7:0] hold;
    // ioctl_wait power-up value is NOT optional -- sh_download.sv:76-88.
    reg busy = 1'b0;

    assign ioctl_wait = busy;
    assign dl_active = (ioctl_download & is_rom) | busy;

    always @(posedge clk) begin
        if (rst) begin
            dl_req <= 1'b0;
            busy   <= 1'b0;
            hold   <= 8'd0;
        end else begin
            if (dl_req && dl_ack) begin
                dl_req <= 1'b0;
                busy   <= 1'b0;
            end

            if (ioctl_wr && is_rom) begin
                if (!ioctl_addr[0]) begin
                    hold <= ioctl_dout;               // even byte -> [15:8]
                end else begin
                    dl_addr <= base + ioctl_addr[25:1];
                    dl_data <= {hold, ioctl_dout};
                    dl_req  <= 1'b1;
                    busy    <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
