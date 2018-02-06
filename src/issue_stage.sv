// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 21.05.2017
// Description: Issue stage dispatches instructions to the FUs and keeps track of them
//              in a scoreboard like data-structure.

import ariane_pkg::*;

module issue_stage #(
        parameter int unsigned NR_ENTRIES = 8,
        parameter int unsigned NR_WB_PORTS = 5,
        parameter int unsigned NR_COMMIT_PORTS = 2
)(
    input  logic                                     clk_i,     // Clock
    input  logic                                     rst_ni,    // Asynchronous reset active low
    input  logic                                     test_en_i, // Test Enable

    input  logic                                     flush_unissued_instr_i,
    input  logic                                     flush_i,
    // from Debug
    input  logic                                     debug_gpr_req_i,
    input  logic [4:0]                               debug_gpr_addr_i,
    input  logic                                     debug_gpr_we_i,
    input  logic [63:0]                              debug_gpr_wdata_i,
    output logic [63:0]                              debug_gpr_rdata_o,
    // from ISSUE
    input  scoreboard_entry_t                        decoded_instr_i,
    input  logic                                     decoded_instr_valid_i,
    input  logic                                     is_ctrl_flow_i,
    output logic                                     decoded_instr_ack_o,
    // to EX
    output fu_t                                      fu_o,
    output fu_op                                     operator_o,
    output logic [63:0]                              operand_a_o,
    output logic [63:0]                              operand_b_o,
    output logic [63:0]                              imm_o,
    output logic [TRANS_ID_BITS-1:0]                 trans_id_o,
    output logic [63:0]                              pc_o,
    output logic                                     is_compressed_instr_o,

    input  logic                                     alu_ready_i,
    output logic                                     alu_valid_o,
    // ex just resolved our predicted branch, we are ready to accept new requests
    input  logic                                     resolve_branch_i,

    input  logic                                     lsu_ready_i,
    output logic                                     lsu_valid_o,
    // branch prediction
    input  logic                                     branch_ready_i,
    output logic                                     branch_valid_o, // use branch prediction unit
    output branchpredict_sbe_t                       branch_predict_o,

    input  logic                                     mult_ready_i,
    output logic                                     mult_valid_o,    // Branch predict Out

    input  logic                                     csr_ready_i,
    output logic                                     csr_valid_o,

    // write back port
    input logic [NR_WB_PORTS-1:0][TRANS_ID_BITS-1:0] trans_id_i,

    input logic [NR_WB_PORTS-1:0][63:0]              wbdata_i,
    input exception_t [NR_WB_PORTS-1:0]              ex_ex_i, // exception from execute stage
    input logic [NR_WB_PORTS-1:0]                    wb_valid_i,

    // commit port
    input  logic [NR_COMMIT_PORTS-1:0][4:0]          waddr_i,
    input  logic [NR_COMMIT_PORTS-1:0][63:0]         wdata_i,
    input  logic [NR_COMMIT_PORTS-1:0]               we_i,

    output scoreboard_entry_t [NR_COMMIT_PORTS-1:0]  commit_instr_o,
    input  logic              [NR_COMMIT_PORTS-1:0]  commit_ack_i
);
    // ---------------------------------------------------
    // Scoreboard (SB) <-> Issue and Read Operands (IRO)
    // ---------------------------------------------------
    fu_t  [2**REG_ADDR_SIZE:0] rd_clobber_sb_iro;

    logic [REG_ADDR_SIZE-1:0]  rs1_iro_sb;
    logic [63:0]               rs1_sb_iro;
    logic                      rs1_valid_sb_iro;

    logic [REG_ADDR_SIZE-1:0]  rs2_iro_sb;
    logic [63:0]               rs2_sb_iro;
    logic                      rs2_valid_iro_sb;

    scoreboard_entry_t         issue_instr_sb_rename;
    logic                      issue_instr_valid_sb_rename;
    logic                      issue_ack_rename_sb;

    scoreboard_entry_t         issue_instr_rename_iro;
    logic                      issue_instr_valid_rename_iro;
    logic                      issue_ack_iro_rename;

    // ---------------------------------------------------
    // Branch (resolve) logic
    // ---------------------------------------------------
    // This should basically prevent the scoreboard from accepting
    // instructions past a branch. We need to resolve the branch beforehand.
    // This limitation is in place to ease the backtracking of mis-predicted branches as they
    // can simply be in the front-end of the processor.
    logic unresolved_branch_n, unresolved_branch_q;

    always_comb begin : unresolved_branch
        unresolved_branch_n = unresolved_branch_q;
        // we just resolved the branch
        if (resolve_branch_i) begin
            unresolved_branch_n = 1'b0;
        end
        // if the instruction is valid, it is a control flow instruction and the issue stage acknowledged its dispatch
        // set the unresolved branch flag
        if (issue_ack_iro_rename && decoded_instr_valid_i && is_ctrl_flow_i) begin
            unresolved_branch_n = 1'b1;
        end
        // if we predicted a taken branch this means that we need to stall issue for one cycle to resolve the
        // branch, otherwise we might issue a wrong instruction
        if (issue_ack_iro_rename && decoded_instr_i.bp.valid && decoded_instr_i.bp.predict_taken) begin
            unresolved_branch_n = 1'b1;
        end
        // if we are requested to flush also flush the unresolved branch flag because either the flush
        // was requested by a branch or an exception. In any case: any unresolved branch will get evicted
        if (flush_unissued_instr_i || flush_i) begin
            unresolved_branch_n = 1'b0;
        end
    end
    // ---------------------------------------------------------
    // 1. Issue instruction and read operand
    // ---------------------------------------------------------
    issue_read_operands i_issue_read_operands  (
        .flush_i             ( flush_unissued_instr_i          ),
        .issue_instr_i       ( issue_instr_rename_iro          ),
        .issue_instr_valid_i ( issue_instr_valid_rename_iro    ),
        .issue_ack_o         ( issue_ack_iro_rename            ),
        .rs1_o               ( rs1_iro_sb                      ),
        .rs1_i               ( rs1_sb_iro                      ),
        .rs1_valid_i         ( rs1_valid_sb_iro                ),
        .rs2_o               ( rs2_iro_sb                      ),
        .rs2_i               ( rs2_sb_iro                      ),
        .rs2_valid_i         ( rs2_valid_iro_sb                ),
        .rd_clobber_i        ( rd_clobber_sb_iro               ),
        .*
    );

    // ---------------------------------------------------------
    // 2. Re-name
    // ---------------------------------------------------------
    re_name i_re_name (
        .clk_i               ( clk_i                        ),
        .rst_ni              ( rst_ni                       ),
        .issue_instr_i       ( issue_instr_sb_rename        ),
        .issue_instr_valid_i ( issue_instr_valid_sb_rename  ),
        .issue_ack_o         ( issue_ack_rename_sb          ),
        .issue_instr_o       ( issue_instr_rename_iro       ),
        .issue_instr_valid_o ( issue_instr_valid_rename_iro ),
        .issue_ack_i         ( issue_ack_iro_rename         )
    );

    // ---------------------------------------------------------
    // 3. Manage issued instructions in a scoreboard
    // ---------------------------------------------------------
    scoreboard  #(
        .NR_ENTRIES            ( NR_ENTRIES                                ),
        .NR_WB_PORTS           ( NR_WB_PORTS                               )
    ) i_scoreboard (
        .unresolved_branch_i   ( unresolved_branch_q && !resolve_branch_i  ),
        .rd_clobber_o          ( rd_clobber_sb_iro                         ),
        .rs1_i                 ( rs1_iro_sb                                ),
        .rs1_o                 ( rs1_sb_iro                                ),
        .rs1_valid_o           ( rs1_valid_sb_iro                          ),
        .rs2_i                 ( rs2_iro_sb                                ),
        .rs2_o                 ( rs2_sb_iro                                ),
        .rs2_valid_o           ( rs2_valid_iro_sb                          ),

        .issue_instr_o         ( issue_instr_sb_rename                     ),
        .issue_instr_valid_o   ( issue_instr_valid_sb_rename               ),
        .issue_ack_i           ( issue_ack_rename_sb                       ),

        .trans_id_i            ( trans_id_i                                ),
        .wbdata_i              ( wbdata_i                                  ),
        .ex_i                  ( ex_ex_i                                   ),
        .*
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            unresolved_branch_q <= 1'b0;
        end else begin
            unresolved_branch_q <= unresolved_branch_n;
        end
    end

endmodule

// Author: Florian Zaruba, ETH Zurich
// Date: 03.10.2017
// Description: Re-name registers
module re_name (
    input  logic                                   clk_i,    // Clock
    input  logic                                   rst_ni,   // Asynchronous reset active low
    // coming from scoreboard
    input  scoreboard_entry_t                      issue_instr_i,
    input  logic                                   issue_instr_valid_i,
    output logic                                   issue_ack_o,
    // coming from scoreboard
    output scoreboard_entry_t                      issue_instr_o,
    output logic                                   issue_instr_valid_o,
    input  logic                                   issue_ack_i
);

    // pass through handshaking signals
    assign issue_instr_valid_o = issue_instr_valid_i;
    assign issue_ack_o         = issue_ack_i;

    // keep track of re-naming data structures
    logic [31:0] re_name_table_n, re_name_table_q;

    // -------------------
    // Re-naming
    // -------------------
    always_comb begin

        // default assignments
        re_name_table_n = re_name_table_q;
        issue_instr_o   = issue_instr_i;

        if (issue_ack_i) begin
            // if we acknowledge the instruction tic the corresponding register
            re_name_table_n[issue_instr_i.rd] = re_name_table_q[issue_instr_i.rd] ^ 1'b1;
        end

        // re-name the source registers
        issue_instr_o.rs1 = { re_name_table_q[issue_instr_i.rs1], issue_instr_i.rs1 };
        issue_instr_o.rs2 = { re_name_table_q[issue_instr_i.rs1], issue_instr_i.rs2 };

        // we don't want to re-name register zero, it is non-writeable anyway
        re_name_table_n[0] = 1'b0;
    end

    // -------------------
    // Registers
    // -------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(~rst_ni) begin
            re_name_table_q <= '0;
        end else begin
            re_name_table_q <= re_name_table_n;
        end
    end
endmodule
