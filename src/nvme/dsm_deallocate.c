/*
 * dsm_deallocate.c
 * NVMe Dataset Management - Deallocate support for Cosmos+ OpenSSD.
 *
 * Design:
 *  - Deallocate is treated as a hint.
 *  - Only FTL mapping units (slices, 16KB) fully covered by a range are
 *    invalidated. Partially covered slices are left untouched.
 *  - InvalidateOldVsa() is reused, so the block's invalid slice count and the
 *    GC victim list are updated exactly as they are on an overwrite.
 *  - A slice still present in the DRAM data buffer is skipped. Otherwise a
 *    later eviction of that buffer entry would map the slice again.
 *  - A range that reaches beyond the exposed capacity is ignored as a whole.
 *
 * Accounting (all in bytes, see exp_stat.h):
 *    requested = invalidated + already_free + busy_skip + ignored
 *
 * Known limits:
 *  - GC runs synchronously inside the write path of this FTL, so it cannot be
 *    in progress while this handler runs. Overlap with NAND requests that are
 *    still queued is not checked here and has to be tested on the board.
 *  - Data read from a deallocated range is undefined (DLFEAT is not set).
 */
#include "dsm_deallocate.h"

#include "host_lld.h"

#include "../ftl_config.h"
#include "../address_translation.h"
#include "../data_buffer.h"
#include "../request_transform.h"
#include "../exp_stat.h"

#define DSM_BYTES_PER_SLICE	((exp_u64)BYTES_PER_DATA_REGION_OF_SLICE)

/* data_buffer.h declares "dataBufHashTable", but the variable defined in
 * data_buffer.c is "dataBufHashTablePtr". Using the header name does not link. */
extern P_DATA_BUF_HASH_TABLE dataBufHashTablePtr;

/*
 * Copy the range list from host memory to DSM_PAYLOAD_BUFFER_ADDR.
 * Returns 0 when the list cannot be fetched.
 */
static DATASET_MANAGEMENT_RANGE *DsmFetchPayload(unsigned int cmdSlotTag, NVME_IO_COMMAND *nvmeIOCmd, unsigned int nr)
{
#if DSM_PAYLOAD_USE_AUTO_DMA
	(void)nvmeIOCmd;
	(void)nr;

	set_auto_rx_dma(cmdSlotTag, 0, DSM_PAYLOAD_BUFFER_ADDR, NVME_COMMAND_AUTO_COMPLETION_OFF);
	check_auto_rx_dma_done();
#else
	unsigned int len, firstLen;

	(void)cmdSlotTag;

	//set_direct_rx_dma() asserts on an address that is not 4-byte aligned
	if((nvmeIOCmd->PRP1[0] & 0x3) != 0)
		return 0;

	len = nr * sizeof(DATASET_MANAGEMENT_RANGE);
	firstLen = 0x1000 - (nvmeIOCmd->PRP1[0] & 0xFFF);	//bytes left in the first host page

	if(len <= firstLen)
		set_direct_rx_dma(DSM_PAYLOAD_BUFFER_ADDR, nvmeIOCmd->PRP1[1], nvmeIOCmd->PRP1[0], len);
	else
	{
		if((nvmeIOCmd->PRP2[0] & 0x3) != 0)
			return 0;

		set_direct_rx_dma(DSM_PAYLOAD_BUFFER_ADDR, nvmeIOCmd->PRP1[1], nvmeIOCmd->PRP1[0], firstLen);
		set_direct_rx_dma(DSM_PAYLOAD_BUFFER_ADDR + firstLen, nvmeIOCmd->PRP2[1], nvmeIOCmd->PRP2[0], len - firstLen);
	}
	check_direct_rx_dma_done();
#endif

	return (DATASET_MANAGEMENT_RANGE *)DSM_PAYLOAD_BUFFER_ADDR;
}

/* Is the logical slice held by an entry of the DRAM data buffer? */
static int DsmSliceInDataBuffer(unsigned int lsa)
{
	unsigned int entry;

	entry = dataBufHashTablePtr->dataBufHash[FindDataBufHashTableEntry(lsa)].headEntry;

	while(entry != DATA_BUF_NONE)
	{
		if(dataBufMapPtr->dataBuf[entry].logicalSliceAddr == lsa)
			return 1;

		entry = dataBufMapPtr->dataBuf[entry].hashNextEntry;
	}

	return 0;
}

/*
 * Process [slba, slba + nlb). Returns the requested bytes of the range.
 */
static exp_u64 DsmProcessRange(DATASET_MANAGEMENT_RANGE *range)
{
	unsigned int slba, nlb, firstSlice, endSlice, lsa;
	exp_u64 reqBytes, handledBytes;

	slba = range->startingLBA[0];
	nlb = range->lengthInLogicalBlocks;
	reqBytes = (exp_u64)nlb * BYTES_PER_NVME_BLOCK;
	handledBytes = 0;

	if(nlb == 0)
		return 0;

	//outside the exposed capacity: ignore the whole range, do not touch the map
	if((range->startingLBA[1] != 0) || (slba >= storageCapacity_L) || (nlb > storageCapacity_L - slba))
	{
		exp_on_dsm_ignored(reqBytes);
		return reqBytes;
	}

	firstSlice = (slba + NVME_BLOCKS_PER_SLICE - 1) / NVME_BLOCKS_PER_SLICE;	//round up
	endSlice = (slba + nlb) / NVME_BLOCKS_PER_SLICE;							//round down, exclusive

	for(lsa = firstSlice; lsa < endSlice; lsa++)
	{
		if(logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr == VSA_NONE)
		{
			exp_on_dsm_already_free(DSM_BYTES_PER_SLICE);
			handledBytes += DSM_BYTES_PER_SLICE;
			continue;
		}

		if(DsmSliceInDataBuffer(lsa))
		{
			exp_on_dsm_busy_skip(DSM_BYTES_PER_SLICE);
			handledBytes += DSM_BYTES_PER_SLICE;
			continue;
		}

		InvalidateOldVsa(lsa);

		//InvalidateOldVsa() leaves the mapping alone when the two maps disagree
		if(logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr == VSA_NONE)
		{
			exp_on_dsm_invalidated(DSM_BYTES_PER_SLICE);
			handledBytes += DSM_BYTES_PER_SLICE;
		}
	}

	//partially covered slices at both ends, and slices InvalidateOldVsa() refused
	exp_on_dsm_ignored(reqBytes - handledBytes);

	return reqBytes;
}

void HandleDatasetManagement(NVME_COMMAND *nvmeCmd)
{
	NVME_IO_COMMAND *nvmeIOCmd;
	DATASET_MANAGEMENT_RANGE *ranges;
	unsigned int nr, ad, i;
	exp_u64 reqBytes = 0;

	exp_dsm_begin();

	nvmeIOCmd = (NVME_IO_COMMAND *)nvmeCmd->cmdDword;

	nr = (nvmeIOCmd->dword10 & 0xFF) + 1;	//NR is zero-based
	ad = (nvmeIOCmd->dword11 >> 2) & 0x1;	//Attribute - Deallocate

	//IDR/IDW are hints this firmware does not use: AD = 0 completes without any change
	if(ad)
	{
		ranges = DsmFetchPayload(nvmeCmd->cmdSlotTag, nvmeIOCmd, nr);

		if(ranges != 0)
		{
			for(i = 0; i < nr; i++)
				reqBytes += DsmProcessRange(&ranges[i]);
		}
		else
			exp_on_dsm_error();
	}

	exp_on_dsm_cmd(nr, reqBytes);

	//same completion path as Flush
	set_auto_nvme_cpl(nvmeCmd->cmdSlotTag, 0, 0);

	exp_dsm_end();
}
