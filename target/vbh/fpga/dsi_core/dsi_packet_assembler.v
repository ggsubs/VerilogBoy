/* 
 * DSI Core
 * Copyright (C) 2013-2014 twl <twlostow@printf.cc>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.

 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.

 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */


`include "dsi_defs.vh"

`timescale 1ns/1ps

/* 
 * dsi_packet_assembler.v
 *
 * Puts together DSI packets and produces a packed data stream for the PHY.
 */

module dsi_packet_assembler
    (
    clk_i,
    rst_n_i,
    p_req_i,
    p_islong_i,
    p_type_i,
    p_wcount_i,
    p_command_i,
    p_payload_i,
    p_dreq_o,
    p_dlast_o,
    p_last_i,

    phy_d_o,
    phy_dvalid_o,
    phy_hs_request_o,
    phy_hs_dreq_i
    );

    parameter g_bytes_per_pixel = 2;

    input         clk_i;
    input         rst_n_i;

    input                     p_req_i;
    input                     p_islong_i;
    input [5:0]               p_type_i;
    input [15:0]              p_wcount_i;
    input [15:0]              p_command_i;
    input [g_bytes_per_pixel * 8-1:0] p_payload_i;
    input                     p_last_i;
   
    output                    p_dreq_o;
    output                    p_dlast_o;
    output [7:0]              phy_d_o;
    output                    phy_dvalid_o;
   
    output                    phy_hs_request_o;
    input                     phy_hs_dreq_i;
   
`define ST_LP_MODE 3
`define ST_IDLE 0
`define ST_PAYLOAD 1
`define ST_CRC 2
`define ST_HEADER 4

    reg [3:0]                 state;
    reg [15:0]                tx_count;
    wire [15:0]               tx_count_next;
   
    reg [31:0]                pack_data;
    wire                      pack_req;
    reg                       pack_req_d0;
   
    reg [3:0]                 pack_size;
    reg                       pack_valid;
    wire                      pack_empty;
    reg                       pack_flush;
    wire                      pack_qvalid;
   
   
    dsi_packer
    #(
        .g_input_bytes(4), // could be up to 4 bytes
        .g_output_bytes(1)
    )
    U_Packer
    (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
      
        .d_i(pack_data),
        .d_size_i(pack_size),
        .d_req_o(pack_req),
        .d_valid_i(pack_valid),
        .d_empty_o(pack_empty),

        .q_o(phy_d_o),
        .q_req_i(phy_hs_dreq_i),
        .q_valid_o(pack_qvalid),
        .q_flush_i(pack_flush),
        .q_size_i(3'd1)
    );

    reg            crc_reset,crc_valid;
    wire [15:0]    crc_value;
    reg [2:0]      crc_nbytes = g_bytes_per_pixel;
   
    dsi_crc
    #(
        .g_max_data_bytes(g_bytes_per_pixel)
    ) 
    U_CRC 
    (
        .clk_i(clk_i),
        .rst_i(crc_reset),
        .valid_i(crc_valid),
        .nbytes_i(crc_nbytes),
        .d_i(p_payload_i),
        .crc_o(crc_value)
    );

    reg [23:0]     pack_header;
    wire [23:0]    pack_header_swapped;
   
    wire [7:0]     ecc_value;
   
    always @(*)
    begin
        if(p_islong_i)
            pack_header = { 2'b00, p_type_i, p_wcount_i[7:0], p_wcount_i[15:8] };
        else
            pack_header = { 2'b00, p_type_i, p_command_i[7:0], p_command_i[15:8] };
    end
    
    assign pack_header_swapped [7:0] = pack_header[23:16];
    assign pack_header_swapped [15:8] = pack_header[15:8];
    assign pack_header_swapped [23:16] = pack_header[7:0];
   
   
    dsi_parity U_ECC 
    (
        .d_i(pack_header_swapped),
        .p_o(ecc_value)
    );
   

    always @(*)
    begin
        crc_valid = (state == `ST_PAYLOAD ? pack_req_d0 : 0);
        crc_reset = (state == `ST_IDLE ? 1: 0 );
    end

    assign p_idle_o = (state == `ST_IDLE || state == `ST_LP_MODE);

    always@(posedge clk_i)
        pack_req_d0 <= pack_req;
   
    always@(posedge clk_i)
    begin
        if(!rst_n_i) begin
            state <= `ST_LP_MODE;
            tx_count <= 0;
        end else begin
            case (state)
            `ST_LP_MODE: begin
                tx_count <= 0;
                if(p_req_i && pack_req_d0 && phy_hs_dreq_i) begin
                    state <= `ST_IDLE;
                end
            end
          
            `ST_IDLE:  begin
                if(pack_req_d0) begin
                        tx_count <= pack_size - 1;
                        state <= `ST_HEADER;
                end else if(!p_req_i)
                    state <= `ST_LP_MODE;
             
            end // case: `ST_IDLE
            
            `ST_HEADER: begin
                if (tx_count == 1) begin
                    if(p_islong_i) begin
                        state <= `ST_PAYLOAD;
                        tx_count <= p_wcount_i;
                    end
                    else begin
                        tx_count <= tx_count - 1;
                        if(p_last_i)
                            state <= `ST_LP_MODE;
                        else
                            state <= `ST_IDLE;
                    end
                end
                else
                    tx_count <= tx_count - 1;
            end
          
            `ST_PAYLOAD: begin
                if(pack_valid)
                begin
                    if(tx_count == g_bytes_per_pixel) begin
                        tx_count <= 1;
                        state <= `ST_CRC;
                    end
                    else begin
                        tx_count <= tx_count - g_bytes_per_pixel;
                        if(!p_req_i)
                            state <= `ST_LP_MODE;
                    end
                end
            end
          
            `ST_CRC: begin
                if(pack_req_d0) begin
                    state <= `ST_IDLE;
                    tx_count <= 0;
                end
            end
            endcase // case (state)
        end // else: !if(!rst_n_i)
    end

    always@(*)
    begin
        case (state)
        `ST_LP_MODE: begin
            pack_data  = (`DSI_SYNC_SEQ);
            pack_size  = 1;
            pack_valid = pack_req_d0 && p_req_i && phy_hs_dreq_i;
            pack_flush = ~p_req_i;
        end

        `ST_IDLE:  begin
            pack_data  = ({pack_header, ecc_value});
            pack_size  = 4;
            pack_valid = pack_req_d0;
            pack_flush = 0;
        end
        
        `ST_HEADER:  begin
            pack_data  = ({pack_header, ecc_value});
            pack_size  = 4;
            pack_valid = 0;
            pack_flush = 0;
        end

        `ST_PAYLOAD:  begin
            pack_data  = p_payload_i;
            pack_size  = g_bytes_per_pixel;
            pack_valid = pack_req_d0;
            pack_flush = 0;
        end
      
        `ST_CRC:  begin
            pack_data  = {crc_value[7:0], crc_value[15:8]};
            pack_size  = 2;
            pack_valid = pack_req_d0;
            pack_flush = ~p_req_i;
        end

        default: begin
            pack_data  = 0;
            pack_size  = 1;
            pack_valid = 0;
            pack_flush = 0;
        end
        endcase // case (state)
    end
   
    assign phy_hs_request_o = p_req_i || (state != `ST_LP_MODE) || !pack_empty;
    assign phy_dvalid_o = pack_qvalid;

    reg p_dreq;

    assign p_dreq_o = p_dreq;

    always @(*)
    begin
        case(state)
        `ST_PAYLOAD: begin
            if (tx_count == g_bytes_per_pixel && pack_valid)
                p_dreq = 0;
            else
                p_dreq = pack_req & p_req_i & phy_hs_dreq_i;
        end
    
        `ST_CRC: begin
            p_dreq = pack_req & p_req_i & phy_hs_dreq_i & pack_valid;
        end      
        default: p_dreq = pack_req & p_req_i & phy_hs_dreq_i;
        endcase
    end

endmodule // dsi_packet_assembler


