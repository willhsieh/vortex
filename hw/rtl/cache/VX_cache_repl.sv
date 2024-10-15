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

`include "VX_cache_define.vh"

// Fast PLRU encoder and decoder utility
// Adapted from BaseJump STL: http://bjump.org/data_out.html

module plru_decoder #(
    parameter NUM_WAYS      = 1,
    parameter WAY_IDX_BITS  = $clog2(NUM_WAYS),
    parameter WAY_IDX_WIDTH = `UP(WAY_IDX_BITS)
) (
    input wire [WAY_IDX_WIDTH-1:0] way_idx,
    input wire [`UP(NUM_WAYS-1)-1:0] lru_in,
    output wire [`UP(NUM_WAYS-1)-1:0] lru_out
);
    if (NUM_WAYS > 1) begin : g_dec
        wire [`UP(NUM_WAYS-1)-1:0] data;
    `IGNORE_UNOPTFLAT_BEGIN
        wire [`UP(NUM_WAYS-1)-1:0] mask;
    `IGNORE_UNOPTFLAT_END
        for (genvar i = 0; i < NUM_WAYS-1; ++i) begin : g_i
            if (i == 0) begin : g_i_0
                assign mask[i] = 1'b1;
            end else if (i % 2 == 1) begin : g_i_odd
                assign mask[i] = mask[(i-1)/2] & ~way_idx[WAY_IDX_BITS-$clog2(i+2)+1];
            end else begin : g_i_even
                assign mask[i] = mask[(i-2)/2] & way_idx[WAY_IDX_BITS-$clog2(i+2)+1];
            end
            assign data[i] = ~way_idx[WAY_IDX_BITS-$clog2(i+2)];
        end
        assign lru_out = (data & mask) | (lru_in & ~mask);
    end else begin : g_no_dec
        `UNUSED_VAR (way_idx)
        `UNUSED_VAR (lru_in)
        assign lru_out = '0;
    end

endmodule

module plru_encoder #(
    parameter NUM_WAYS      = 1,
    parameter WAY_IDX_BITS  = $clog2(NUM_WAYS),
    parameter WAY_IDX_WIDTH = `UP(WAY_IDX_BITS)
) (
    input wire [`UP(NUM_WAYS-1)-1:0] lru_in,
    output wire [WAY_IDX_WIDTH-1:0] way_idx
);
    if (NUM_WAYS > 1) begin : g_enc
        wire [WAY_IDX_BITS-1:0] tmp;
        for (genvar i = 0; i < WAY_IDX_BITS; ++i) begin : g_i
            VX_mux #(
                .N (2**i)
            ) mux (
                .data_in  (lru_in[((2**i)-1)+:(2**i)]),
                .sel_in   (tmp[WAY_IDX_BITS-1-:i]),
                .data_out (tmp[WAY_IDX_BITS-1-i])
            );
        end
        assign way_idx = tmp;
    end else begin : g_no_enc
        `UNUSED_VAR (lru_in)
        assign way_idx = '0;
    end

endmodule

module VX_cache_repl #(
    parameter CACHE_SIZE = 1024,
    // Size of line inside a bank in bytes
    parameter LINE_SIZE  = 64,
    // Number of banks
    parameter NUM_BANKS  = 1,
    // Number of associative ways
    parameter NUM_WAYS   = 1,
    // replacement policy
    parameter REPL_POLICY = `CS_REPL_CYCLIC
) (
    input wire clk,
    input wire reset,
    input wire stall,
    input wire hit_valid,
    input wire [`CS_LINE_SEL_BITS-1:0] hit_line,
    input wire [NUM_WAYS-1:0] hit_way,
    input wire repl_valid,
    input wire [`CS_LINE_SEL_BITS-1:0] repl_line,
    output wire [NUM_WAYS-1:0] repl_way
);
    `UNUSED_VAR (stall)

    localparam WAY_IDX_BITS = $clog2(NUM_WAYS);
    localparam WAY_IDX_WIDTH = `UP(WAY_IDX_BITS);

    if (REPL_POLICY == `CS_REPL_PLRU) begin : g_plru
        // Pseudo Least Recently Used replacement policy
        localparam LRU_WIDTH = NUM_WAYS-1;
        `UNUSED_VAR (repl_valid)

        reg [`UP(LRU_WIDTH)-1:0] plru_tree [0:`CS_LINES_PER_BANK-1];

        wire [WAY_IDX_WIDTH-1:0] repl_way_idx;
        wire [WAY_IDX_WIDTH-1:0] hit_way_idx;
        wire [`UP(LRU_WIDTH)-1:0] plru_update;

        always @(posedge clk) begin
            if (reset) begin
                plru_tree <= '0;
            end else begin
                if (hit_valid) begin
                    plru_tree[hit_line] <= plru_update;
                end
            end
        end

        VX_onehot_encoder #(
            .N (NUM_WAYS)
        ) hit_way_enc (
            .data_in  (hit_way),
            .data_out (hit_way_idx),
            `UNUSED_PIN (valid_out)
        );

        plru_decoder #(
            .NUM_WAYS (NUM_WAYS)
        ) plru_dec (
            .way_idx (hit_way_idx),
            .lru_in  (plru_tree[hit_line]),
            .lru_out (plru_update)
        );

        plru_encoder #(
            .NUM_WAYS (NUM_WAYS)
        ) plru_enc (
            .lru_in  (plru_tree[repl_line]),
            .way_idx (repl_way_idx)
        );

        VX_decoder #(
            .N (WAY_IDX_BITS)
        ) repl_way_dec (
            .sel_in   (repl_way_idx),
            .data_in  (1'b1),
            .data_out (repl_way)
        );

    end else if (REPL_POLICY == `CS_REPL_CYCLIC) begin : g_cyclic
        // Cyclic replacement policy
        localparam CTR_WIDTH = $clog2(NUM_WAYS);
        `UNUSED_VAR (hit_valid)
        `UNUSED_VAR (hit_line)
        `UNUSED_VAR (hit_way)
        reg [`UP(CTR_WIDTH)-1:0] counters [0:`CS_LINES_PER_BANK-1];
        always @(posedge clk) begin
            if (repl_valid) begin
                counters[repl_line] <= counters[repl_line] + 1;
            end
        end
        VX_decoder #(
            .N (WAY_IDX_BITS)
        ) ctr_decoder (
            .sel_in   (counters[repl_line]),
            .data_in  (1'b1),
            .data_out (repl_way)
        );
    end else begin : g_random
        // Random replacement policy
        `UNUSED_VAR (hit_valid)
        `UNUSED_VAR (hit_line)
        `UNUSED_VAR (hit_way)
        `UNUSED_VAR (repl_valid)
        `UNUSED_VAR (repl_line)
        if (NUM_WAYS > 1) begin : g_repl_way
            reg [NUM_WAYS-1:0] victim_way;
            always @(posedge clk) begin
                if (reset) begin
                    victim_way <= 1;
                end else if (~stall) begin
                    victim_way <= {victim_way[NUM_WAYS-2:0], victim_way[NUM_WAYS-1]};
                end
            end
            assign repl_way = victim_way;
        end else begin : g_repl_way_1
            `UNUSED_VAR (clk)
            `UNUSED_VAR (reset)
            assign repl_way = 1'b1;
        end
    end

endmodule
