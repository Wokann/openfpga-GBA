`timescale 1ns/1ps
module tb_cart_header_probe;
    reg clk=0, reset_n=0, start=0, ready=0;
    always #5 clk=~clk;
    wire req, done, present;
    wire [1:0] addr;
    reg [31:0] data=0;
    integer pattern=0, accesses=0;
    cart_header_probe #(.TIMEOUT(30)) dut (
        .clk(clk), .reset_n(reset_n), .start(start), .rd_req(req),
        .rd_addr(addr), .rd_ready(ready), .rd_data(data), .done(done), .present(present)
    );
    always @(negedge clk) begin
        ready=0;
        if (req) begin
            if (addr !== (accesses % 4)) $fatal(1,"probe left header range / wrong pass restart");
            data = pattern==1 ? 32'hFFFFFFFF : pattern==2 ? 0 : 32'h12345678 ^ addr;
            if (pattern==3 && accesses==7) data=data^1;
            if (pattern!=4) ready=1;
            accesses=accesses+1;
        end
    end
    task test_pattern(input integer p, input bit expected);
        begin
            @(negedge clk); reset_n=0; start=0; pattern=p; accesses=0;
            repeat(3) @(negedge clk);
            reset_n=1; start=1;
            wait(done); #1;
            if (present !== expected) $fatal(1,"probe pattern %0d: present=%b",p,present);
            if (p!=4 && accesses!=8) $fatal(1,"expected eight DWORD reads");
            repeat(10) @(negedge clk);
            if (req) $fatal(1,"probe restarted without reset");
        end
    endtask
    initial begin
        test_pattern(0,1); test_pattern(1,0); test_pattern(2,0);
        test_pattern(3,0); test_pattern(4,0);
        $display("PASS: header match, all-FF, all-zero, last-word mismatch, timeout, reset");
        $finish;
    end
    initial begin #100000; $fatal(1,"probe test timeout"); end
endmodule
