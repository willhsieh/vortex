// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

module VX_gpr_slice import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0,
    parameter CACHE_ENABLE = 0
) (
    input wire              clk,
    input wire              reset,

    VX_writeback_if.slave   writeback_if,
    VX_scoreboard_if.slave  scoreboard_if,
    VX_operands_if.master   operands_if
);
    `UNUSED_PARAM (CORE_ID)
    localparam DATAW = `UUID_WIDTH + ISSUE_WIS_W + `NUM_THREADS + `PC_BITS + 1 + `EX_BITS + `INST_OP_BITS + `INST_ARGS_BITS + `NR_BITS;
    localparam RAM_ADDRW = `LOG2UP(`NUM_REGS * PER_ISSUE_WARPS);

    localparam STATE_IDLE   = 2'd0;
    localparam STATE_FETCH1 = 2'd1;
    localparam STATE_FETCH2 = 2'd2;
    localparam STATE_FETCH3 = 2'd3;
    localparam STATE_BITS   = 2;

    wire [`NUM_THREADS-1:0][`XLEN-1:0] gpr_rd_data;
    reg [`NR_BITS-1:0] gpr_rd_rid, gpr_rd_rid_n;
    reg [ISSUE_WIS_W-1:0] gpr_rd_wis, gpr_rd_wis_n;

    reg [`NUM_THREADS-1:0][`XLEN-1:0] cache_data [PER_ISSUE_WARPS-1:0];
    reg [`NUM_THREADS-1:0][`XLEN-1:0] cache_data_n [PER_ISSUE_WARPS-1:0];
    reg [`NR_BITS-1:0] cache_reg [PER_ISSUE_WARPS-1:0];
    reg [`NR_BITS-1:0] cache_reg_n [PER_ISSUE_WARPS-1:0];
    reg [`NUM_THREADS-1:0] cache_tmask [PER_ISSUE_WARPS-1:0];
    reg [`NUM_THREADS-1:0] cache_tmask_n [PER_ISSUE_WARPS-1:0];
    reg [PER_ISSUE_WARPS-1:0] cache_eop, cache_eop_n;

    reg [`NUM_THREADS-1:0][`XLEN-1:0] rs1_data, rs1_data_n;
    reg [`NUM_THREADS-1:0][`XLEN-1:0] rs2_data, rs2_data_n;
    reg [`NUM_THREADS-1:0][`XLEN-1:0] rs3_data, rs3_data_n;

    reg [STATE_BITS-1:0] state, state_n;
    reg [`NR_BITS-1:0] rs2, rs2_n;
    reg [`NR_BITS-1:0] rs3, rs3_n;
    reg rs2_ready, rs2_ready_n;
    reg rs3_ready, rs3_ready_n;
    reg data_ready, data_ready_n;

    wire stg_valid_in, stg_ready_in;

    wire is_rs1_zero = (scoreboard_if.data.rs1 == 0);
    wire is_rs2_zero = (scoreboard_if.data.rs2 == 0);
    wire is_rs3_zero = (scoreboard_if.data.rs3 == 0);

    always @(*) begin
        state_n      = state;
        rs2_n        = rs2;
        rs3_n        = rs3;
        rs2_ready_n  = rs2_ready;
        rs3_ready_n  = rs3_ready;
        rs1_data_n   = rs1_data;
        rs2_data_n   = rs2_data;
        rs3_data_n   = rs3_data;
        cache_data_n = cache_data;
        cache_reg_n  = cache_reg;
        cache_tmask_n= cache_tmask;
        cache_eop_n  = cache_eop;
        gpr_rd_rid_n = gpr_rd_rid;
        gpr_rd_wis_n = gpr_rd_wis;
        data_ready_n = data_ready;

        case (state)
        STATE_IDLE: begin
            if (operands_if.valid && operands_if.ready) begin
                data_ready_n = 0;
            end
            if (scoreboard_if.valid && data_ready_n == 0) begin
                data_ready_n = 1;
                if (is_rs3_zero || (CACHE_ENABLE != 0 &&
                                    scoreboard_if.data.rs3 == cache_reg[scoreboard_if.data.wis] &&
                                    (scoreboard_if.data.tmask & cache_tmask[scoreboard_if.data.wis]) == scoreboard_if.data.tmask)) begin
                    rs3_data_n   = (is_rs3_zero || CACHE_ENABLE == 0) ? '0 : cache_data[scoreboard_if.data.wis];
                    rs3_ready_n  = 1;
                end else begin
                    rs3_ready_n  = 0;
                    gpr_rd_rid_n = scoreboard_if.data.rs3;
                    data_ready_n = 0;
                    state_n      = STATE_FETCH3;
                end
                if (is_rs2_zero || (CACHE_ENABLE != 0 &&
                                    scoreboard_if.data.rs2 == cache_reg[scoreboard_if.data.wis] &&
                                    (scoreboard_if.data.tmask & cache_tmask[scoreboard_if.data.wis]) == scoreboard_if.data.tmask)) begin
                    rs2_data_n   = (is_rs2_zero || CACHE_ENABLE == 0) ? '0 : cache_data[scoreboard_if.data.wis];
                    rs2_ready_n  = 1;
                end else begin
                    rs2_ready_n  = 0;
                    gpr_rd_rid_n = scoreboard_if.data.rs2;
                    data_ready_n = 0;
                    state_n      = STATE_FETCH2;
                end
                if (is_rs1_zero || (CACHE_ENABLE != 0 &&
                                    scoreboard_if.data.rs1 == cache_reg[scoreboard_if.data.wis] &&
                                    (scoreboard_if.data.tmask & cache_tmask[scoreboard_if.data.wis]) == scoreboard_if.data.tmask)) begin
                    rs1_data_n   = (is_rs1_zero || CACHE_ENABLE == 0) ? '0 : cache_data[scoreboard_if.data.wis];
                end else begin
                    gpr_rd_rid_n = scoreboard_if.data.rs1;
                    data_ready_n = 0;
                    state_n      = STATE_FETCH1;
                end
            end
            gpr_rd_wis_n = scoreboard_if.data.wis;
            rs2_n = scoreboard_if.data.rs2;
            rs3_n = scoreboard_if.data.rs3;
        end
        STATE_FETCH1: begin
            rs1_data_n = gpr_rd_data;
            if (~rs2_ready) begin
                gpr_rd_rid_n = rs2;
                state_n = STATE_FETCH2;
            end else if (~rs3_ready) begin
                gpr_rd_rid_n = rs3;
                state_n = STATE_FETCH3;
            end else begin
                data_ready_n = 1;
                state_n = STATE_IDLE;
            end
        end
        STATE_FETCH2: begin
            rs2_data_n = gpr_rd_data;
            if (~rs3_ready) begin
                gpr_rd_rid_n = rs3;
                state_n = STATE_FETCH3;
            end else begin
                data_ready_n = 1;
                state_n = STATE_IDLE;
            end
        end
        STATE_FETCH3: begin
            rs3_data_n = gpr_rd_data;
            data_ready_n = 1;
            state_n = STATE_IDLE;
        end
        endcase

        if (CACHE_ENABLE != 0 && writeback_if.valid) begin
            if ((cache_reg[writeback_if.data.wis] == writeback_if.data.rd)
             || (cache_eop[writeback_if.data.wis] && writeback_if.data.sop)) begin
                for (integer j = 0; j < `NUM_THREADS; ++j) begin
                    if (writeback_if.data.tmask[j]) begin
                        cache_data_n[writeback_if.data.wis][j] = writeback_if.data.data[j];
                    end
                end
                cache_reg_n[writeback_if.data.wis] = writeback_if.data.rd;
                cache_eop_n[writeback_if.data.wis] = writeback_if.data.eop;
                cache_tmask_n[writeback_if.data.wis] = writeback_if.data.sop ? writeback_if.data.tmask :
                                                                (cache_tmask_n[writeback_if.data.wis] | writeback_if.data.tmask);
            end
        end
    end

    always @(posedge clk)  begin
        if (reset) begin
            state       <= STATE_IDLE;
            cache_eop   <= {PER_ISSUE_WARPS{1'b1}};
            data_ready  <= 0;
        end else begin
            state       <= state_n;
            cache_eop   <= cache_eop_n;
            data_ready  <= data_ready_n;
        end
        gpr_rd_rid  <= gpr_rd_rid_n;
        gpr_rd_wis  <= gpr_rd_wis_n;
        rs2_ready   <= rs2_ready_n;
        rs3_ready   <= rs3_ready_n;
        rs2         <= rs2_n;
        rs3         <= rs3_n;
        rs1_data    <= rs1_data_n;
        rs2_data    <= rs2_data_n;
        rs3_data    <= rs3_data_n;
        cache_data  <= cache_data_n;
        cache_reg   <= cache_reg_n;
        cache_tmask <= cache_tmask_n;
    end

    assign stg_valid_in = scoreboard_if.valid && data_ready;
    assign scoreboard_if.ready = stg_ready_in && data_ready;

    VX_toggle_buffer #(
        .DATAW (DATAW)
    ) toggle_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (stg_valid_in),
        .data_in   ({
            scoreboard_if.data.uuid,
            scoreboard_if.data.wis,
            scoreboard_if.data.tmask,
            scoreboard_if.data.PC,
            scoreboard_if.data.wb,
            scoreboard_if.data.ex_type,
            scoreboard_if.data.op_type,
            scoreboard_if.data.op_args,
            scoreboard_if.data.rd
        }),
        .ready_in  (stg_ready_in),
        .valid_out (operands_if.valid),
        .data_out  ({
            operands_if.data.uuid,
            operands_if.data.wis,
            operands_if.data.tmask,
            operands_if.data.PC,
            operands_if.data.wb,
            operands_if.data.ex_type,
            operands_if.data.op_type,
            operands_if.data.op_args,
            operands_if.data.rd
        }),
        .ready_out (operands_if.ready)
    );

    assign operands_if.data.rs1_data = rs1_data;
    assign operands_if.data.rs2_data = rs2_data;
    assign operands_if.data.rs3_data = rs3_data;

    // GPR banks

    reg [RAM_ADDRW-1:0] gpr_rd_addr;
    wire [RAM_ADDRW-1:0] gpr_wr_addr;
    if (ISSUE_WIS != 0) begin
        assign gpr_wr_addr = {writeback_if.data.wis, writeback_if.data.rd};
        always @(posedge clk) begin
            gpr_rd_addr <= {gpr_rd_wis_n, gpr_rd_rid_n};
        end
    end else begin
        assign gpr_wr_addr = writeback_if.data.rd;
        always @(posedge clk) begin
            gpr_rd_addr <= gpr_rd_rid_n;
        end
    end

`ifdef GPR_RESET
    reg wr_enabled = 0;
    always @(posedge clk) begin
        if (reset) begin
            wr_enabled <= 1;
        end
    end
`endif

    for (genvar j = 0; j < `NUM_THREADS; ++j) begin
        VX_dp_ram #(
            .DATAW (`XLEN),
            .SIZE (`NUM_REGS * PER_ISSUE_WARPS),
        `ifdef GPR_RESET
            .INIT_ENABLE (1),
            .INIT_VALUE (0),
        `endif
            .NO_RWCHECK (1)
        ) gpr_ram (
            .clk   (clk),
            .read  (1'b1),
            `UNUSED_PIN (wren),
        `ifdef GPR_RESET
            .write (wr_enabled && writeback_if.valid && writeback_if.data.tmask[j]),
        `else
            .write (writeback_if.valid && writeback_if.data.tmask[j]),
        `endif
            .waddr (gpr_wr_addr),
            .wdata (writeback_if.data.data[j]),
            .raddr (gpr_rd_addr),
            .rdata (gpr_rd_data[j])
        );
    end

endmodule
