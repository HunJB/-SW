/*
 * PC test for src/nvme/dsm_deallocate.c and src/exp_stat.c.
 * The two firmware files are compiled unchanged; hardware access is replaced
 * by the small functions below. This checks range arithmetic and counters,
 * not DMA or timing on the real board.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "xtime_l.h"
#include "nvme/nvme.h"
#include "ftl_config.h"
#include "address_translation.h"
#include "data_buffer.h"
#include "exp_stat.h"
#include "nvme/dsm_deallocate.h"

/* ---- firmware globals the module reads ---- */
P_LOGICAL_SLICE_MAP logicalSliceMapPtr;
P_DATA_BUF_MAP dataBufMapPtr;
P_DATA_BUF_HASH_TABLE dataBufHashTablePtr;
unsigned int storageCapacity_L;

/* ---- stand-ins for hardware and FTL functions ---- */
static unsigned char hostmem[2 * 4096];	/* PRP1 page, PRP2 page */
static int cplCnt, invalCalls, dmaCalls;
static unsigned int refuseLsa = 0xFFFFFFFF;

void xil_printf(const char *f, ...) { (void)f; }
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
void set_auto_rx_dma(unsigned int tag, unsigned int off, unsigned int dev, unsigned int ac)
{
	(void)tag; (void)off; (void)ac;
	memcpy((void *)(unsigned long)dev, hostmem, 4096);
	dmaCalls++;
}
void check_auto_rx_dma_done(void) {}
void set_auto_nvme_cpl(unsigned int a, unsigned int b, unsigned int c)
{
	(void)a;
	if (b != 0 || c != 0) { printf("FAIL: completion is not success\n"); exit(2); }
	cplCnt++;
}
void InvalidateOldVsa(unsigned int lsa)
{
	invalCalls++;
	if (lsa == refuseLsa)	/* the real function returns early when the two maps disagree */
		return;
	logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr = VSA_NONE;
}

/* ---- helpers ---- */
static int fails;
#define CHK(x) do { if (!(x)) { printf("FAIL line %d: %s\n", __LINE__, #x); fails++; } } while (0)
#define S (&g_exp_stat)
#define SLICE 16384ULL
#define LBA 4096ULL

static void put(unsigned i, unsigned long long slba, unsigned nlb, unsigned off)
{
	DATASET_MANAGEMENT_RANGE r;
	memset(&r, 0, sizeof r);
	r.lengthInLogicalBlocks = nlb;
	r.startingLBA[0] = (unsigned int)slba;
	r.startingLBA[1] = (unsigned int)(slba >> 32);
	memcpy(hostmem + off + i * 16, &r, 16);
}

static void run(unsigned nr, unsigned prp1, unsigned ad)
{
	NVME_COMMAND cmd;
	NVME_IO_COMMAND *c = (NVME_IO_COMMAND *)cmd.cmdDword;
	memset(&cmd, 0, sizeof cmd);
	cmd.cmdSlotTag = 1;
	c->OPC = IO_NVM_DATASET_MANAGEMENT;
	c->dword10 = nr - 1;
	c->dword11 = ad << 2;
	c->PRP1[0] = prp1;
	c->PRP2[0] = 0x1000;
	HandleDatasetManagement(&cmd);
}

static void buffer_put(unsigned entry, unsigned lsa)	/* put one slice into the data buffer hash */
{
	unsigned b = FindDataBufHashTableEntry(lsa);
	dataBufMapPtr->dataBuf[entry].logicalSliceAddr = lsa;
	dataBufMapPtr->dataBuf[entry].hashNextEntry = dataBufHashTablePtr->dataBufHash[b].headEntry;
	dataBufHashTablePtr->dataBufHash[b].headEntry = entry;
}

static exp_u64 sum(const exp_u64 *a, unsigned n) { exp_u64 s = 0; while (n--) s += a[n]; return s; }

int main(int argc, char **argv)
{
	unsigned i;
	exp_u64 inv, cmds;

	if (mmap((void *)(unsigned long)DSM_PAYLOAD_BUFFER_ADDR, 8192, PROT_READ | PROT_WRITE,
	         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) { perror("mmap"); return 2; }

	logicalSliceMapPtr = malloc(sizeof(LOGICAL_SLICE_MAP));
	dataBufMapPtr = calloc(1, sizeof(DATA_BUF_MAP));
	dataBufHashTablePtr = malloc(sizeof(DATA_BUF_HASH_TABLE));
	for (i = 0; i < AVAILABLE_DATA_BUFFER_ENTRY_COUNT; i++)
		dataBufHashTablePtr->dataBufHash[i].headEntry = DATA_BUF_NONE;
	storageCapacity_L = 1000000;	/* 4KB blocks */
	for (i = 0; i < SLICES_PER_SSD; i++)	/* slices 0..999 are written */
		logicalSliceMapPtr->logicalSlice[i].virtualSliceAddr = (i < 1000) ? i : VSA_NONE;
	exp_stat_init();

	/* 1. aligned range: LBA 0..63 = 16 slices */
	put(0, 0, 64, 0); run(1, 0, 1);
	CHK(S->dsm_cmd_count == 1); CHK(S->dsm_range_count == 1);
	CHK(S->dsm_req_bytes == 64 * LBA); CHK(S->dsm_invalid_bytes == 16 * SLICE); CHK(S->dsm_ignored_bytes == 0);

	/* 2. same range again: nothing new, counted as already free */
	run(1, 0, 1);
	CHK(S->dsm_invalid_bytes == 16 * SLICE); CHK(S->dsm_already_free_bytes == 16 * SLICE);

	/* 3. boundaries: LBA 65..74 covers only slice 17 (LBA 68..71) fully -> 6 blocks ignored */
	put(0, 65, 10, 0); run(1, 0, 1);
	CHK(S->dsm_invalid_bytes == 17 * SLICE); CHK(S->dsm_ignored_bytes == 6 * LBA);
	CHK(logicalSliceMapPtr->logicalSlice[16].virtualSliceAddr != VSA_NONE);
	CHK(logicalSliceMapPtr->logicalSlice[17].virtualSliceAddr == VSA_NONE);
	CHK(logicalSliceMapPtr->logicalSlice[18].virtualSliceAddr != VSA_NONE);

	/* 4. range inside one slice: all ignored */
	put(0, 81, 2, 0); run(1, 0, 1);
	CHK(S->dsm_ignored_bytes == 8 * LBA); CHK(S->dsm_invalid_bytes == 17 * SLICE);

	/* 5. beyond the capacity: ignored as a whole, map untouched */
	inv = S->dsm_invalid_bytes; i = invalCalls;
	put(0, 999999, 5, 0); run(1, 0, 1);
	put(0, 0xFFFFFFF0ULL, 0x20, 0); run(1, 0, 1);
	put(0, 0x100000000ULL, 4, 0); run(1, 0, 1);
	CHK(S->dsm_ignored_bytes == (8 + 5 + 0x20 + 4) * LBA); CHK(S->dsm_invalid_bytes == inv); CHK((unsigned)invalCalls == i);

	/* 6. AD = 0: completed, counted, nothing changed, payload not fetched */
	inv = S->dsm_invalid_bytes; i = dmaCalls; cmds = S->dsm_cmd_count;
	put(0, 400, 64, 0); run(1, 0, 0);
	CHK(S->dsm_invalid_bytes == inv); CHK((unsigned)dmaCalls == i); CHK(S->dsm_cmd_count == cmds + 1);

	/* 7. slice held in the data buffer is skipped and stays mapped */
	buffer_put(3, 205); buffer_put(4, 205 + AVAILABLE_DATA_BUFFER_ENTRY_COUNT);	/* same hash bucket */
	inv = S->dsm_invalid_bytes;
	put(0, 800, 32, 0); run(1, 0, 1);	/* slices 200..207 */
	CHK(S->dsm_invalid_bytes == inv + 7 * SLICE); CHK(S->dsm_busy_skip_bytes == SLICE);
	CHK(logicalSliceMapPtr->logicalSlice[205].virtualSliceAddr != VSA_NONE);

	/* 8. InvalidateOldVsa() refuses one slice: counted as ignored, not as invalidated */
	refuseLsa = 301; inv = S->dsm_invalid_bytes; cmds = S->dsm_ignored_bytes;
	put(0, 1200, 8, 0); run(1, 0, 1);	/* slices 300, 301 */
	CHK(S->dsm_invalid_bytes == inv + SLICE); CHK(S->dsm_ignored_bytes == cmds + SLICE);
	refuseLsa = 0xFFFFFFFF;

	/* 9. zero-length range and several ranges in one command */
	inv = S->dsm_invalid_bytes;
	put(0, 1600, 0, 0); put(1, 1600, 4, 0); put(2, 1608, 4, 0); run(3, 0, 1);	/* slices 400, 402 */
	CHK(S->dsm_invalid_bytes == inv + 2 * SLICE);

#if !DSM_PAYLOAD_USE_AUTO_DMA
	/* 10. 256 ranges starting at page offset 0x800: 2048 bytes via PRP1, 2048 via PRP2 */
	inv = S->dsm_invalid_bytes; i = dmaCalls;
	for (i = 0; i < 256; i++) put(i, 2000 + i * 8, 4, 0x800);	/* slices 500, 502, ... 1010 */
	i = dmaCalls; run(256, 0x800, 1);
	CHK(dmaCalls - i == 2); CHK(S->dsm_invalid_bytes == inv + 250 * SLICE);

	/* 11. payload address not 4-byte aligned: no DMA, error counted, still completed */
	i = dmaCalls; inv = S->dsm_invalid_bytes;
	put(0, 3600, 64, 0); run(1, 0x2, 1);
	CHK((unsigned)dmaCalls == i); CHK(S->dsm_error_count == 1); CHK(S->dsm_invalid_bytes == inv);
#endif

	/* totals */
	CHK(S->dsm_req_bytes == S->dsm_invalid_bytes + S->dsm_already_free_bytes +
	                        S->dsm_busy_skip_bytes + S->dsm_ignored_bytes);
	CHK((exp_u64)cplCnt == S->dsm_cmd_count);
	CHK(S->dsm_nesting_error == 0); CHK(S->dsm_ticks_total > 0);
	CHK(sum(S->dsm_hist_ticks, EXP_HIST_TICKS_NR) == S->dsm_cmd_count);
	CHK(sum(S->dsm_hist_lba, EXP_HIST_LBA_NR) == S->dsm_cmd_count);
	CHK(exp_log2_bucket(0, 8) == 0); CHK(exp_log2_bucket(1, 8) == 0); CHK(exp_log2_bucket(2, 8) == 1);
	CHK(exp_log2_bucket(1023, 32) == 9); CHK(exp_log2_bucket(1024, 32) == 10); CHK(exp_log2_bucket(~0ULL, 8) == 7);
	CHK(sizeof(exp_stat_t) % 8 == 0);
	CHK(EXP_SNAPSHOT_HEADER_NR * 8 + sizeof(exp_stat_t) <= EXP_SNAPSHOT_BYTES);

	/* snapshot files for the parser check: argv[1] = before, argv[2] = after */
	if (argc == 3) {
		static unsigned char buf[EXP_SNAPSHOT_BYTES];
		exp_u64 *f = (exp_u64 *)&g_exp_stat;
		unsigned n = sizeof(exp_stat_t) / 8;
		FILE *fp;

		for (i = 0; i < n; i++) f[i] = 1000 + i;	/* field i holds 1000 + i */
		exp_stat_snapshot(buf);
		fp = fopen(argv[1], "wb"); fwrite(buf, 1, sizeof buf, fp); fclose(fp);
		for (i = 0; i < n; i++) f[i] = 1000 + i + (i + 1) * 7;	/* difference of field i is 7 * (i + 1) */
		exp_stat_snapshot(buf);
		fp = fopen(argv[2], "wb"); fwrite(buf, 1, sizeof buf, fp); fclose(fp);
	}

	printf("%s: %d failure(s)\n", DSM_PAYLOAD_USE_AUTO_DMA ? "auto DMA build" : "direct DMA build", fails);
	return fails ? 1 : 0;
}
