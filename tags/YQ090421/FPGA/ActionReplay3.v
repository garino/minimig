// Copyright 2008, 2009 by Jakub Bednarski
//
// This file is part of Minimig
//
// Minimig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// Minimig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
//
//
// JB:
// This module is based on information from WinUAE code (ar.c), the internet (How to Code the Amiga) 
// and examination of Action Replay code.
// You need Action Replay rom file (named "AR3.ROM").
// The bootloader loads this file at $400000-43ffff (256KB).
// If bootloader writes to that location it enables Action Replay. 
// It also takes one 512KB RAM bank so max. 1MB for Amiga RAM is left.
// Tested with Action Replay III rom version 3.17. 
// This ROM only works with kickstart 1.3 and 2.04 (37.175).
//
// Custom register shadow memory ($44f000-$44f1ff) contains all actual values, not only those written by the CPU.
//
// Freeze button is Ctrl+Break.
//
// Breeakpoints don't work entirely as they should:
// when breakpoint is triggered, immediate exit with "x" command doesn't arm breakpoint circuit,
// doing a step trace ("tr" command) and then exit works ok: consecutive breakpoint triggers.
//
//
// 2008-03-25		- first version, INT7 freeze button
// 2008-03-26		- loading of ROM @ $400000
// 2008-03-27		- mode register, ram overlay and INT7 on reset
// 2008-03-28		- custom register shadow
// 2008-03-29		- custom register shadow written from RGA bus
// 2008-03-30		- mem watch breakpoint circuit 
// 2008-04-11		- AR style breakpoint circuit 
// 2008-07-10		- added disabling of AR when no ROM was uploaded
// 2008-07-17		- code clean up
// 2008-07-28		- code clean up
// 2008-10-07		- improvements for 28MHz CPU

module ActionReplay
(
	output	[2:0] test,
	input	clk,
	input	reset,
	input	[23:1] cpuaddress,
	input	cpuclk,
	input	_as,
	input	[8:1] regaddress,
	input	[15:0] datain,
	output	[15:0] dataout,
	input	cpurd,
	input	cpuhwr,
	input	cpulwr,
	input	dma,
	input	boot,
	output	ovr,
	input	freeze,
	output	reg int7,
	output	selmem,
	output	reg aron = 0
);

reg		freeze_del;
wire	freeze_req;
wire	int7_req;
wire	int7_ack;
reg		l_int7_req;
reg		l_int7_ack;
reg		l_int7;
wire	reset_req;
wire	break_req;
reg		after_reset;
reg		[1:0]mode;
reg		[1:0]status;
reg		ram_ovl;	//override chip memory and show its rom for int7 vector
reg		active;		//cartridge is active (rom is visible)

wire	sel_cart;	//select cartridge cpu space ($400000-$47ffff)
wire	sel_rom;	//select rom space ($400004-$43ffff)
wire	sel_ram;	//select rom space ($440000-$47ffff) - ($44F000-$44F1FF)
wire 	sel_custom;	//select custom register shadow ($44F000-$44F1FF)
wire	sel_status;	//status register $400000-$400003 (repeated twice)
wire	sel_mode;	//mode register $400000/1

//output signals
wire	[15:0]custom_out;
wire	[15:0]status_out;

//-------------------------------------------------------------------------------------------------

//see above
assign sel_cart = aron & ~dma & (cpuaddress[23:19]==5'b0100_0);
assign sel_rom = sel_cart & ~cpuaddress[18] & |cpuaddress[17:2];
assign sel_ram = sel_cart & cpuaddress[18] & (cpuaddress[17:9]!=9'b001111_000);
assign sel_custom = sel_cart & cpuaddress[18] & (cpuaddress[17:9]==9'b001111_000) & cpurd;
assign sel_mode = sel_cart & ~|cpuaddress[18:1];
assign sel_status = sel_cart & ~|cpuaddress[18:2] & cpurd;
assign sel_ovl = ram_ovl & (cpuaddress[23:19]==5'b0000_0) & cpurd;
assign selmem = (sel_rom&boot) | (((sel_rom&cpurd) | sel_ram | sel_ovl));

//Action Replay is activated by writing to its ROM area during bootloading
always @(posedge clk)
	if (boot && cpuaddress[23:18]==6'b0100_00 && cpulwr)
		aron <= 1;	//rom will miss first write but since 2 first words of rom are not readable it doesn't matter

//delayed signal for edge dettection
always @(posedge clk)
	freeze_del <= freeze;

//freeze button has been pressed
assign freeze_req = freeze & ~freeze_del & ~active;

//int7 request
assign int7_req = aron & ~boot & (freeze_req | reset_req | break_req);

//level7 interrupt ack cycle, on Amiga interrupt vector number is read from kickstart rom
//A[23:4] all high, A[3:1] vector number
assign int7_ack = &cpuaddress & ~_as;

//level 7 interrupt request logic
// interrupt request lines are sampled during S4->S5 transition (falling cpu clock edge)
//always @(posedge clk)
always @(posedge cpuclk)
	if (reset)
		int7 <= 0;
	else if (int7_req)
		int7 <= 1;
	else if (int7_ack)
		int7 <= 0;
		
always @(posedge clk)
	{l_int7_req,l_int7_ack} <= {int7_req,int7_ack};

always @(posedge clk)
	if (reset)
		l_int7 <= 0;
	else if (l_int7_req)
		l_int7 <= 1;
	else if (l_int7_ack && cpurd)
		l_int7 <= 0;
		
assign test = {mode[1],mode[0],break_req};

//triggers int7 when first CPU write after reset to memory location $8
// AR rom checks if PC==$FC0144 or $F80160, other kickstarts need to path these values
//_IPLx lines are sampled durring S4->S5 transition, _AS is asserted during S2, 
//if we assert _IPLx lines too late the AR rom code won't properly recognize this request
assign reset_req = ~boot & (cpuaddress[23:1]==23'h04) & ~_as & after_reset;

//set after reset, cleared by first INT7 req
always @(posedge cpuclk)
	if (reset)
		after_reset <= 1;
	else if (int7_ack)
		after_reset <= 0;

//chip ram overlay, when INT7 is active AR rom apears in chipram area
//cleared by write to $400006
always @(posedge clk)
	if (reset)
		ram_ovl <= 0;
	else if (l_int7 && l_int7_ack && cpurd) //once again we don't know the state of CPU's FCx signals
		ram_ovl <= 1;
	else if (sel_rom && (cpuaddress[2:1]==2'b11) && (cpuhwr|cpulwr))
		ram_ovl <= 0;

//when INT7 is activated AR's rom and ram apear in its address space ($400000-$47FFFF)
//this flag is cleared by write to $400000 (see code at  $4013DA)
//since we miss CPU's FC signals we cannot distinguish data and code access
//so we don't hide AR's rom and ram
always @(posedge clk)
	if (reset)
		active <= 0;
	else if (l_int7 && l_int7_ack && cpurd)//once again we don't know the state of CPU's FC signals
		active <= 1;
	else if (sel_mode && (cpuaddress[2:1]==2'b00) && (cpuhwr|cpulwr))
		active <= 0;

//override chipram decoding (externally gated with rd)
assign ovr = ram_ovl;

//===============================================================================================//

// setting mode[1] enables breakpoint circuity
// don't know yet why but exiting immediately from breakpoint with 'x' command doesn't enable brekpoints (mode=0)
// preceeding 'x' with 'tr' works ok
always @(posedge clk)
	if (reset)
		mode <= 2'b11;
	else if (sel_mode && cpulwr)	//cpu write to mode register
		mode <= datain[1:0];

always @(posedge clk)
	if (reset)
		status <= 2'b11;
	else if (freeze_req)			//freeze button pressed
		status <= 2'b00;
	else if (break_req)			//breakpoint raised
		status <= 2'b01;

assign status_out = sel_status ? {14'h00,status} : 16'h00_00;


//===============================================================================================//
//custom registers shadow memory - all writes by cpu and dma are reflected
reg		[15:0]custom[255:0];
reg		[8:1]custom_adr;

//use clocked address to infer blockram
always @(negedge clk)
	custom_adr[8:1] <= cpuaddress[8:1];

// custom registers shadow buffer write
always @(posedge clk)
	custom[regaddress] <= datain;

// custom registers shadow buffer read
assign custom_out = sel_custom ? custom[custom_adr[8:1]] : 16'h00_00;

//===============================================================================================//

//dataout multiplexer
assign dataout = custom_out | status_out;

//===============================================================================================//

//===============================================================================================//
///TRACE:
//150: 4A39 00BF E001   TST.B BFE001
//156: 60F8             BRA   150
//BREAKPOINT:
//040: 4A39 00BF E001   TST.B BFE001
//046: 60F8             BRA   040
//MEMWATCH:
//130: 4A39 00BF E001   TST.B BFE001
//136: 4E71             NOP
//138: 4E71             NOP

//Action Replay is activated when memory at address $BFE001 is accessed from $000-$400

reg	cpuaddress_hit;

//address range access $000-$3FF		
always @(posedge _as)
	cpuaddress_hit <= cpuaddress[23:10]==14'h00 ? 1 : 0;

//access of $BFE001 from $000-$3FF memory range
assign break_req = mode[1] && cpuaddress_hit && cpuaddress==(24'hBFE001>>1) && !_as ? 1 : 0;

endmodule