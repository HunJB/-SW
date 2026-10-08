/*
 * PC test for src/nvme/dsm_deallocate.c and src/exp_stat.c.
 * The two firmware files are compiled unchanged; hardware access and the few
 * FTL functions they call are replaced by the stand-ins below. This checks
 * range arithmetic, buffer handling and counters, not DMA or timing on the board.
 * With a file argument it also writes real exp_stat_dump() output there, so
 * tools/parse_expstat.py can check it reads every field the firmware prints.
 */
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "xtime_l.h"
#include "nvme/nvme.h"
#include "ftl_config.h"
#include "address_translation.h"
#include "data_buffer.h"
#include "request_allocation.h"
#include "memory_map.h"
#include "exp_stat.h"
#include "nvme/dsm_deallocate.h"

/* ---- firmware globals the module reads ---- */
P_LOGICAL_SLICE_MAP logicalSliceMapPtr;
P_DATA_BUF_MAP dataBufMapPtr;
P_DATA_BUF_HASH_TABLE dataBufHashTablePtr;
P_TEMPORARY_DATA_BUF_MAP tempDataBufMapPtr;
unsigned int storageCapacity_L;

/* same address the module computes (first 4KB page after the baseline payload area) */
#define PAYLOAD_ADDR ((((unsigned long)TEMPORARY_PAY_LOAD_ADDR) + 0x1FFFUL) & ~0xFFFUL)

/* ---- stand-ins ---- */
static unsigned char hostmem[2 * 4096];	/* PRP1 page, PRP2 page */
static int cplCnt, dmaCalls, invalCalls;
static unsigned int lastSC;

static FILE *uartFp;	/* where xil_printf goes (the UART log for the parser check) */
void xil_printf(const char *f, ...)
{
	va_list ap;
	if (!uartFp) return;
	va_start(ap, f);
	vfprintf(uartFp, f, ap);
	va_end(ap);
}
void XTime_GetTime(XTime *t) { static XTime n; *t = n += 1000; }
void XTime_SetTime(XTime t) { (void)t; }

void set_direct_rx_dma(unsigned int dev, unsigned int h, unsigned int l, unsigned int len)
{
	(void)h;
	if (len > 0x1000 || (l & 3)) { printf("FAIL: bad direct DMA len=%u addr=%x\n", len, l); exit(2); }
	memcpy((void *)(unsigned long)dev, hostmem + (l & 0x1FFF), len);
	dmaCalls++;
}
void check_direct_rx_dma_done(void) {}
void set_auto_nvme_cpl(unsigned int tag, unsigned int specific, unsigned int status)
{
	(void)tag; (void)specific;
	lastSC = (status >> 1) & 0xFF;	/* statusFieldWord: bit 0 phase, bits 8:1 SC */
	cplCnt++;
}
void InvalidateOldVsa(unsigned int lsa)
{
	invalCalls++;
	logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr = VSA_NONE;
}
/* copy of the logic in data_buffer.c */
void SelectiveGetFromDataBufHashList(unsigned int e)
{
	if (dataBufMapPtr->dataBuf[e].logicalSliceAddr != LSA_NONE) {
		unsigned int p = dataBufMapPtr->dataBuf[e].hashPrevEntry, n = dataBufMapPtr->dataBuf[e].hashNextEntry;
		unsigned int h = FindDataBufHashTableEntry(dataBufMapPtr->dataBuf[e].logicalSliceAddr);
		if (n != DATA_BUF_NONE && p != DATA_BUF_NONE) { dataBufMapPtr->dataBuf[p].hashNextEntry = n; dataBufMapPtr->dataBuf[n].hashPrevEntry = p; }
		else if (n == DATA_BUF_NONE && p != DATA_BUF_NONE) { dataBufMapPtr->dataBuf[p].hashNextEntry = DATA_BUF_NONE; dataBufHashTablePtr->dataBufHash[h].tailEntry = p; }
		else if (n != DATA_BUF_NONE && p == DATA_BUF_NONE) { dataBufMapPtr->dataBuf[n].hashPrevEntry = DATA_BUF_NONE; dataBufHashTablePtr->dataBufHash[h].headEntry = n; }
		else { dataBufHashTablePtr->dataBufHash[h].headEntry = DATA_BUF_NONE; dataBufHashTablePtr->dataBufHash[h].tailEntry = DATA_BUF_NONE; }
	}
}

/* ---- helpers ---- */
static int fails;
#define CHK(x) do { if (!(x)) { printf("FAIL line %d: %s\n", __LINE__, #x); fails++; } } while (0)
#define S (&g_exp_stat)
#define D (&dsmStats)
#define SLICE 16384ULL
#define LBA 4096ULL
#define MAPPED(l) (logicalSliceMapPtr->logicalSlice[l].virtualSliceAddr != VSA_NONE)

static void put(unsigned i, unsigned long long slba, unsigned nlb, unsigned off)
{
	DATASET_MANAGEMENT_RANGE r;
	memset(&r, 0, sizeof r);
	r.lengthInLogicalBlocks = nlb;
	r.startingLBA[0] = (unsigned int)slba;
	r.startingLBA[1] = (unsigned int)(slba >> 32);
	memcpy(hostmem + off + i * 16, &r, 16);
}

static void run_ns(unsigned nr, unsigned prp1, unsigned ad, unsigned nsid)
{
	NVME_COMMAND cmd;
	NVME_IO_COMMAND *c = (NVME_IO_COMMAND *)cmd.cmdDword;
	memset(&cmd, 0, sizeof cmd);
	cmd.cmdSlotTag = 1;
	c->OPC = IO_NVM_DATASET_MANAGEMENT;
	c->NSID = nsid;
	c->dword10 = nr - 1;
	c->dword11 = ad << 2;
	c->PRP1[0] = prp1;
	c->PRP2[0] = 0x1000;
	HandleDatasetManagement(&cmd);
}
#define run(nr, prp1, ad) run_ns((nr), (prp1), (ad), 1)

static void buffer_put(unsigned e, unsigned lsa, int dirty)	/* one data buffer entry in the hash */
{
	unsigned h = FindDataBufHashTableEntry(lsa);
	DATA_BUF_ENTRY *b = &dataBufMapPtr->dataBuf[e];
	b->logicalSliceAddr = lsa;
	b->dirty = dirty ? DATA_BUF_DIRTY : DATA_BUF_CLEAN;
	b->blockingReqTail = REQ_SLOT_TAG_NONE;
	b->hashPrevEntry = dataBufHashTablePtr->dataBufHash[h].tailEntry;
	b->hashNextEntry = DATA_BUF_NONE;
	if (b->hashPrevEntry != DATA_BUF_NONE) dataBufMapPtr->dataBuf[b->hashPrevEntry].hashNextEntry = e;
	else dataBufHashTablePtr->dataBufHash[h].headEntry = e;
	dataBufHashTablePtr->dataBufHash[h].tailEntry = e;
}
static int in_hash(unsigned lsa)
{
	unsigned e = dataBufHashTablePtr->dataBufHash[FindDataBufHashTableEntry(lsa)].headEntry;
	for (; e != DATA_BUF_NONE; e = dataBufMapPtr->dataBuf[e].hashNextEntry)
		if (dataBufMapPtr->dataBuf[e].logicalSliceAddr == lsa) return 1;
	return 0;
}

#define BALANCED() (S->dsm_req_bytes - rejectedReq == S->dsm_invalid_bytes + S->dsm_already_free_bytes + S->dsm_ignored_bytes)

int main(int argc, char **argv)
{
	unsigned i;
	exp_u64 inv, ign, rejectedReq = 0, x;

	if (mmap((void *)PAYLOAD_ADDR, 8192, PROT_READ | PROT_WRITE,
	         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) { perror("mmap"); return 2; }

	logicalSliceMapPtr = malloc(sizeof(LOGICAL_SLICE_MAP));
	dataBufMapPtr = calloc(1, sizeof(DATA_BUF_MAP));
	dataBufHashTablePtr = malloc(sizeof(DATA_BUF_HASH_TABLE));
	tempDataBufMapPtr = malloc(sizeof(TEMPORARY_DATA_BUF_MAP));
	for (i = 0; i < AVAILABLE_DATA_BUFFER_ENTRY_COUNT; i++) {
		dataBufHashTablePtr->dataBufHash[i].headEntry = DATA_BUF_NONE;
		dataBufHashTablePtr->dataBufHash[i].tailEntry = DATA_BUF_NONE;
		dataBufMapPtr->dataBuf[i].logicalSliceAddr = LSA_NONE;
	}
	for (i = 0; i < AVAILABLE_TEMPORARY_DATA_BUFFER_ENTRY_COUNT; i++)
		tempDataBufMapPtr->tempDataBuf[i].blockingReqTail = REQ_SLOT_TAG_NONE;
	storageCapacity_L = 1000000;	/* 4KB blocks */
	for (i = 0; i < SLICES_PER_SSD; i++)	/* slices 0..999 are written */
		logicalSliceMapPtr->logicalSlice[i].virtualSliceAddr = (i < 1000) ? i : VSA_NONE;
	exp_stat_init();
	DsmResetStats();

	/* 1. aligned range: LBA 0..63 = 16 slices */
	put(0, 0, 64, 0); run(1, 0, 1);
	CHK(lastSC == SC_SUCCESSFUL_COMPLETION);
	CHK(S->dsm_cmd_count == 1); CHK(S->dsm_req_bytes == 64 * LBA);
	CHK(S->dsm_invalid_bytes == 16 * SLICE); CHK(S->dsm_ignored_bytes == 0);

	/* 2. same range again: counted as already free */
	run(1, 0, 1);
	CHK(S->dsm_invalid_bytes == 16 * SLICE); CHK(S->dsm_already_free_bytes == 16 * SLICE);

	/* 3. boundaries: LBA 65..74 covers only slice 17 fully -> 6 blocks ignored */
	put(0, 65, 10, 0); run(1, 0, 1);
	CHK(S->dsm_invalid_bytes == 17 * SLICE); CHK(S->dsm_ignored_bytes == 6 * LBA);
	CHK(MAPPED(16)); CHK(!MAPPED(17)); CHK(MAPPED(18));

	/* 4. range inside one slice: all ignored */
	put(0, 81, 2, 0); run(1, 0, 1);
	CHK(S->dsm_ignored_bytes == 8 * LBA); CHK(S->dsm_invalid_bytes == 17 * SLICE);

	/* 5. beyond the capacity: whole command rejected, map untouched */
	inv = S->dsm_invalid_bytes; i = invalCalls; x = S->dsm_req_bytes;
	put(0, 400, 64, 0); put(1, 999999, 5, 0); run(2, 0, 1);
	CHK(lastSC == SC_LBA_OUT_OF_RANGE); CHK(S->dsm_invalid_bytes == inv); CHK((unsigned)invalCalls == i);
	CHK(MAPPED(100)); CHK(D->outOfRangeRanges == 1);
	rejectedReq += S->dsm_req_bytes - x;

	/* 6. AD = 0: completed, counted, nothing changed, payload not fetched */
	inv = S->dsm_invalid_bytes; i = dmaCalls;
	put(0, 400, 64, 0); run(1, 0, 0);
	CHK(lastSC == SC_SUCCESSFUL_COMPLETION); CHK(S->dsm_invalid_bytes == inv); CHK((unsigned)dmaCalls == i);

	/* 7. dirty data buffer entry: skipped, stays mapped, counted as ignored */
	buffer_put(3, 205, 1);
	inv = S->dsm_invalid_bytes; ign = S->dsm_ignored_bytes;
	put(0, 800, 32, 0); run(1, 0, 1);	/* slices 200..207 */
	CHK(S->dsm_invalid_bytes == inv + 7 * SLICE); CHK(S->dsm_ignored_bytes == ign + SLICE);
	CHK(MAPPED(205)); CHK(D->busySkipSlices == 1); CHK(in_hash(205));

	/* 8. clean idle entry: dropped from the cache, then invalidated */
	buffer_put(4, 300, 0); buffer_put(5, 300 + AVAILABLE_DATA_BUFFER_ENTRY_COUNT, 0);	/* same bucket */
	inv = S->dsm_invalid_bytes;
	put(0, 1200, 4, 0); run(1, 0, 1);	/* slice 300 */
	CHK(S->dsm_invalid_bytes == inv + SLICE); CHK(!MAPPED(300)); CHK(!in_hash(300));
	CHK(in_hash(300 + AVAILABLE_DATA_BUFFER_ENTRY_COUNT)); CHK(D->cleanEvictSlices == 1);

	/* 9. adjacent descriptors are merged: [1602,+3) + [1605,+5) = 1602..1609 covers slice 401 (1604..1607);
	 *    neither descriptor covers a whole slice on its own */
	inv = S->dsm_invalid_bytes;
	put(0, 1605, 5, 0); put(1, 1602, 3, 0); run(2, 0, 1);
	CHK(S->dsm_invalid_bytes == inv + SLICE); CHK(!MAPPED(401)); CHK(MAPPED(400)); CHK(MAPPED(402));

	/* 10. GC copy in flight: whole command left alone, counted as ignored */
	tempDataBufMapPtr->tempDataBuf[2].blockingReqTail = 7;
	inv = S->dsm_invalid_bytes; ign = S->dsm_ignored_bytes;
	put(0, 2000, 16, 0); run(1, 0, 1);	/* slices 500..503 */
	CHK(lastSC == SC_SUCCESSFUL_COMPLETION); CHK(S->dsm_invalid_bytes == inv);
	CHK(S->dsm_ignored_bytes == ign + 16 * LBA); CHK(MAPPED(500)); CHK(D->gcBusyCmds == 1);
	tempDataBufMapPtr->tempDataBuf[2].blockingReqTail = REQ_SLOT_TAG_NONE;

	/* 11. 256 ranges starting at page offset 0x800: 2048 bytes via PRP1, 2048 via PRP2 */
	inv = S->dsm_invalid_bytes;
	for (i = 0; i < 256; i++) put(i, 2400 + i * 8, 4, 0x800);	/* slices 600, 602, ... 1110 */
	i = dmaCalls; run(256, 0x800, 1);
	CHK(dmaCalls - i == 2); CHK(S->dsm_invalid_bytes == inv + 200 * SLICE);	/* 600..998 even */

	/* 12. payload address not 4-byte aligned: rejected without DMA */
	i = dmaCalls; inv = S->dsm_invalid_bytes; x = S->dsm_req_bytes;
	put(0, 3600, 64, 0); run(1, 0x2, 1);
	CHK(lastSC == SC_INVALID_FIELD_IN_COMMAND); CHK((unsigned)dmaCalls == i); CHK(S->dsm_invalid_bytes == inv);
	rejectedReq += S->dsm_req_bytes - x;

	/* 13. wrong namespace: rejected */
	run_ns(1, 0, 1, 2);
	CHK(lastSC == SC_INVALID_NAMESPACE_OR_FORMAT); CHK(D->invalidNsidCmds == 1);

	/* totals */
	CHK(BALANCED());
	CHK((exp_u64)cplCnt == S->dsm_cmd_count);
	CHK(S->dsm_nesting_error == 0); CHK(S->dsm_ticks_total > 0);
	CHK(D->cmdCount == S->dsm_cmd_count);
	CHK(D->invalidBytes == S->dsm_invalid_bytes); CHK(D->ignoredBytes == S->dsm_ignored_bytes);

	/* UART output for the parser check: two PERIOD lines with known differences */
	if (argc == 2) {
		uartFp = fopen(argv[1], "w");
		exp_stat_dump("PERIOD");
		S->host_write_bytes += 1234; S->gc_copy_bytes += 56;
		exp_stat_dump("PERIOD");
		fclose(uartFp);
		uartFp = NULL;
	}

	printf("%d failure(s)\n", fails);
	return fails ? 1 : 0;
}
