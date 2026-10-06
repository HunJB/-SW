//////////////////////////////////////////////////////////////////////////////////
// nvme_io_cmd.c for Cosmos+ OpenSSD
// Copyright (c) 2016 Hanyang University ENC Lab.
// Contributed by Yong Ho Song <yhsong@enc.hanyang.ac.kr>
//				  Youngjin Jo <yjjo@enc.hanyang.ac.kr>
//				  Sangjin Lee <sjlee@enc.hanyang.ac.kr>
//				  Jaewook Kwak <jwkwak@enc.hanyang.ac.kr>
//
// This file is part of Cosmos+ OpenSSD.
//
// Cosmos+ OpenSSD is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3, or (at your option)
// any later version.
//
// Cosmos+ OpenSSD is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Cosmos+ OpenSSD; see the file COPYING.
// If not, see <http://www.gnu.org/licenses/>.
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////
// Company: ENC Lab. <http://enc.hanyang.ac.kr>
// Engineer: Sangjin Lee <sjlee@enc.hanyang.ac.kr>
//			 Jaewook Kwak <jwkwak@enc.hanyang.ac.kr>
//
// Project Name: Cosmos+ OpenSSD
// Design Name: Cosmos+ Firmware
// Module Name: NVMe IO Command Handler
// File Name: nvme_io_cmd.c
//
// Version: v1.0.1
//
// Description:
//   - handles NVMe IO command
//////////////////////////////////////////////////////////////////////////////////

//////////////////////////////////////////////////////////////////////////////////
// Revision History:
//
// * v1.0.1
//   - header file for buffer is changed from "ia_lru_buffer.h" to "lru_buffer.h"
//
// * v1.0.0
//   - First draft
//////////////////////////////////////////////////////////////////////////////////


#include "xil_printf.h"
#include "debug.h"
#include "io_access.h"

#include "nvme.h"
#include "host_lld.h"
#include "nvme_io_cmd.h"

#include "../ftl_config.h"
#include "../request_transform.h"
#include "../address_translation.h"	/* EXP */
#include "../exp_stat.h"				/* EXP */

void handle_nvme_io_read(unsigned int cmdSlotTag, NVME_IO_COMMAND *nvmeIOCmd)
{
	IO_READ_COMMAND_DW12 readInfo12;
	//IO_READ_COMMAND_DW13 readInfo13;
	//IO_READ_COMMAND_DW15 readInfo15;
	unsigned int startLba[2];
	unsigned int nlb;

	readInfo12.dword = nvmeIOCmd->dword[12];
	//readInfo13.dword = nvmeIOCmd->dword[13];
	//readInfo15.dword = nvmeIOCmd->dword[15];

	startLba[0] = nvmeIOCmd->dword[10];
	startLba[1] = nvmeIOCmd->dword[11];
	nlb = readInfo12.NLB;

	ASSERT(startLba[0] < storageCapacity_L && (startLba[1] < STORAGE_CAPACITY_H || startLba[1] == 0));
	//ASSERT(nlb < MAX_NUM_OF_NLB);
	ASSERT((nvmeIOCmd->PRP1[0] & 0x3) == 0 && (nvmeIOCmd->PRP2[0] & 0x3) == 0); //error
	ASSERT(nvmeIOCmd->PRP1[1] < 0x10000 && nvmeIOCmd->PRP2[1] < 0x10000);

	ReqTransNvmeToSlice(cmdSlotTag, startLba[0], nlb, IO_NVM_READ);
}


void handle_nvme_io_write(unsigned int cmdSlotTag, NVME_IO_COMMAND *nvmeIOCmd)
{
	IO_READ_COMMAND_DW12 writeInfo12;
	//IO_READ_COMMAND_DW13 writeInfo13;
	//IO_READ_COMMAND_DW15 writeInfo15;
	unsigned int startLba[2];
	unsigned int nlb;

	writeInfo12.dword = nvmeIOCmd->dword[12];
	//writeInfo13.dword = nvmeIOCmd->dword[13];
	//writeInfo15.dword = nvmeIOCmd->dword[15];

	//if(writeInfo12.FUA == 1)
	//	xil_printf("write FUA\r\n");

	startLba[0] = nvmeIOCmd->dword[10];
	startLba[1] = nvmeIOCmd->dword[11];
	nlb = writeInfo12.NLB;

	ASSERT(startLba[0] < storageCapacity_L && (startLba[1] < STORAGE_CAPACITY_H || startLba[1] == 0));
	//ASSERT(nlb < MAX_NUM_OF_NLB);
	ASSERT((nvmeIOCmd->PRP1[0] & 0xF) == 0 && (nvmeIOCmd->PRP2[0] & 0xF) == 0);
	ASSERT(nvmeIOCmd->PRP1[1] < 0x10000 && nvmeIOCmd->PRP2[1] < 0x10000);

	exp_on_host_write((exp_u64)(nlb + 1) * BYTES_PER_NVME_BLOCK);	/* EXP: once per write command */

	ReqTransNvmeToSlice(cmdSlotTag, startLba[0], nlb, IO_NVM_WRITE);
}

/* EXP: minimal Dataset Management (Deallocate) support
 *  - The range list (up to 256 ranges x 16 bytes = 4KB) is fetched with direct DMA.
 *  - Only slices (16KB) fully covered by a range are invalidated.
 *    LBAs that only partly cover a slice are ignored and counted.
 *  - Unmapping reuses InvalidateOldVsa(), the same path an overwrite takes.
 *  - Dirty entries left in the data buffer are not touched (at most 2MB; known limit).
 */
void handle_nvme_io_dataset_management(unsigned int cmdSlotTag, NVME_IO_COMMAND *nvmeIOCmd)
{
	DATASET_MANAGEMENT_RANGE *range;
	NVME_COMPLETION nvmeCPL;
	unsigned int nr, ad, i, len, firstLen;
	unsigned int slba, nlb, firstSlice, endSlice, lsa, fullBlocks;
	exp_u64 reqBytes = 0;

	exp_dsm_begin();

	nr = (nvmeIOCmd->dword10 & 0xFF) + 1;
	ad = (nvmeIOCmd->dword11 >> 2) & 0x1;
	len = nr * sizeof(DATASET_MANAGEMENT_RANGE);

	if(ad && ((nvmeIOCmd->PRP1[0] & 0x3) == 0))
	{
		firstLen = 0x1000 - (nvmeIOCmd->PRP1[0] & 0xFFF);
		if(len <= firstLen)
			set_direct_rx_dma(ADMIN_CMD_DRAM_DATA_BUFFER, nvmeIOCmd->PRP1[1], nvmeIOCmd->PRP1[0], len);
		else
		{
			set_direct_rx_dma(ADMIN_CMD_DRAM_DATA_BUFFER, nvmeIOCmd->PRP1[1], nvmeIOCmd->PRP1[0], firstLen);
			set_direct_rx_dma(ADMIN_CMD_DRAM_DATA_BUFFER + firstLen, nvmeIOCmd->PRP2[1], nvmeIOCmd->PRP2[0], len - firstLen);
		}
		check_direct_rx_dma_done();

		range = (DATASET_MANAGEMENT_RANGE *)ADMIN_CMD_DRAM_DATA_BUFFER;
		for(i = 0; i < nr; i++)
		{
			slba = range[i].startingLBA[0];
			nlb = range[i].lengthInLogicalBlocks;
			reqBytes += (exp_u64)nlb * BYTES_PER_NVME_BLOCK;

			//a range outside the capacity is ignored as a whole
			if((range[i].startingLBA[1] != 0) || (slba >= storageCapacity_L) || (nlb > storageCapacity_L - slba))
			{
				exp_on_dsm_ignored((exp_u64)nlb * BYTES_PER_NVME_BLOCK);
				continue;
			}

			firstSlice = (slba + NVME_BLOCKS_PER_SLICE - 1) / NVME_BLOCKS_PER_SLICE;
			endSlice = (slba + nlb) / NVME_BLOCKS_PER_SLICE;	//exclusive
			fullBlocks = (endSlice > firstSlice) ? (endSlice - firstSlice) * NVME_BLOCKS_PER_SLICE : 0;
			exp_on_dsm_ignored((exp_u64)(nlb - fullBlocks) * BYTES_PER_NVME_BLOCK);

			for(lsa = firstSlice; lsa < endSlice; lsa++)
			{
				if(logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr == VSA_NONE)
				{
					exp_on_dsm_already_free(BYTES_PER_DATA_REGION_OF_SLICE);
					continue;
				}

				InvalidateOldVsa(lsa);

				if(logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr == VSA_NONE)
					exp_on_dsm_invalidated(BYTES_PER_DATA_REGION_OF_SLICE);
				else
					exp_on_dsm_ignored(BYTES_PER_DATA_REGION_OF_SLICE);
			}
		}
	}

	exp_on_dsm_cmd(nr, reqBytes);

	nvmeCPL.dword[0] = 0;
	nvmeCPL.specific = 0x0;
	set_auto_nvme_cpl(cmdSlotTag, nvmeCPL.specific, nvmeCPL.statusFieldWord);

	exp_dsm_end();
}

void handle_nvme_io_cmd(NVME_COMMAND *nvmeCmd)
{
	NVME_IO_COMMAND *nvmeIOCmd;
	NVME_COMPLETION nvmeCPL;
	unsigned int opc;
	nvmeIOCmd = (NVME_IO_COMMAND*)nvmeCmd->cmdDword;
	/*		xil_printf("OPC = 0x%X\r\n", nvmeIOCmd->OPC);
			xil_printf("PRP1[63:32] = 0x%X, PRP1[31:0] = 0x%X\r\n", nvmeIOCmd->PRP1[1], nvmeIOCmd->PRP1[0]);
			xil_printf("PRP2[63:32] = 0x%X, PRP2[31:0] = 0x%X\r\n", nvmeIOCmd->PRP2[1], nvmeIOCmd->PRP2[0]);
			xil_printf("dword10 = 0x%X\r\n", nvmeIOCmd->dword10);
			xil_printf("dword11 = 0x%X\r\n", nvmeIOCmd->dword11);
			xil_printf("dword12 = 0x%X\r\n", nvmeIOCmd->dword12);*/


	opc = (unsigned int)nvmeIOCmd->OPC;

	switch(opc)
	{
		case IO_NVM_FLUSH:
		case IO_NVM_WRITE_ZERO:
		{
		//	xil_printf("IO Flush Command\r\n");
			nvmeCPL.dword[0] = 0;
			nvmeCPL.specific = 0x0;
			set_auto_nvme_cpl(nvmeCmd->cmdSlotTag, nvmeCPL.specific, nvmeCPL.statusFieldWord);
			break;
		}
		case IO_NVM_WRITE:
		{
//			xil_printf("IO Write Command\r\n");
			handle_nvme_io_write(nvmeCmd->cmdSlotTag, nvmeIOCmd);
			break;
		}
		case IO_NVM_READ:
		{
//			xil_printf("IO Read Command\r\n");
			handle_nvme_io_read(nvmeCmd->cmdSlotTag, nvmeIOCmd);
			break;
		}
		case IO_NVM_DATASET_MANAGEMENT:	/* EXP */
		{
			handle_nvme_io_dataset_management(nvmeCmd->cmdSlotTag, nvmeIOCmd);
			break;
		}
		default:
		{
			xil_printf("Not Support IO Command OPC: %X\r\n", opc);
			ASSERT(0);
			break;
		}
	}
}

