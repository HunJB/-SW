/*
 * dsm_deallocate.c
 * NVMe Dataset Management / Deallocate support for Cosmos+ OpenSSD.
 *
 * Safety properties of this revision:
 *  - NSID must be 1.
 *  - Every DSM range is validated in 64-bit arithmetic before any mapping is
 *    changed.  An invalid range fails the whole command without partial
 *    invalidation.
 *  - LSA is never truncated to 32 bits before bounds checking.
 *  - Adjacent/overlapping descriptors in the same DSM command are merged so
 *    split descriptors such as [0,2)+[2,4) behave like [0,4).
 *  - Clean, idle cache entries are evicted before invalidation.  Dirty or
 *    in-flight buffer entries are conservatively skipped and measured.
 *  - Outstanding GC copy requests are detected through the temporary data
 *    buffers used exclusively by GarbageCollection() in the supplied tree.
 *  - The DMA destination is placed in the uncached/non-buffered DRAM region.
 *  - DSM payload uses exact-length direct RX DMA (with PRP1/PRP2 split handling).
 *  - exp_stat DSM counters/timing are updated directly.
 *
 * Remaining design limitation:
 *  - The FTL mapping unit is one 16-KiB slice (4 x 4-KiB LBAs in the supplied
 *    configuration).  A DSM range that does not fully cover a slice cannot be
 *    represented exactly and that partial part is intentionally ignored and
 *    counted.  The host-side experiment should record dsm_ignored_B.
 */
#include "dsm_deallocate.h"

#include "xtime_l.h"
#include "xil_printf.h"

#include "../ftl_config.h"
#include "../address_translation.h"
#include "../data_buffer.h"
#include "../request_allocation.h"
#include "../memory_map.h"
#include "../exp_stat.h"
#include "host_lld.h"

DSM_STATS dsmStats;

typedef struct _DSM_NORMALIZED_RANGE
{
    unsigned long long slba;
    unsigned long long nlb;
} DSM_NORMALIZED_RANGE;

/* CPU-only scratch area; never used as a DMA destination. */
static DSM_NORMALIZED_RANGE dsmRanges[DSM_MAX_RANGES];

/*
 * TEMPORARY_PAY_LOAD_ADDR itself is already used by the baseline firmware.
 * Reserve the first 4-KiB-aligned page after that 4-KiB payload region.
 * main.c maps 0x00200000..0x17ffffff as uncached/non-buffered.
 */
#define DSM_PAYLOAD_ADDR \
    ((((unsigned int)TEMPORARY_PAY_LOAD_ADDR) + 0x1FFFU) & ~0xFFFU)

#define DSM_INVALIDATED        0
#define DSM_ALREADY_UNMAPPED   1
#define DSM_SKIP_BUSY          2
#define DSM_SKIP_RANGE         3

/*
 * Receive the DSM range-descriptor payload with DIRECT RX DMA.
 *
 * Why not auto RX DMA?
 *   Cosmos+ auto RX DMA is organized in 4-KiB command offsets and is used by
 *   the normal NVM read/write request path.  DSM payloads are variable-length
 *   (16 * NR bytes, maximum 4096 bytes).  Using direct RX DMA lets us transfer
 *   the exact payload length and explicitly handle a PRP1 page-boundary split.
 *
 * A DSM payload is at most 4096 bytes, so it can span at most two PRP pages.
 */
static int DsmReceivePayload(NVME_IO_COMMAND *nvmeIOCmd, unsigned int payloadBytes)
{
    unsigned int firstBytes;
    unsigned int secondBytes;
    unsigned int prp1Offset;

    if (payloadBytes == 0 || payloadBytes > DSM_PAYLOAD_BYTES)
        return -1;

    /* set_direct_rx_dma() requires DWORD-aligned PCIe addresses. */
    if ((nvmeIOCmd->PRP1[0] & 0x3U) != 0)
        return -1;

    prp1Offset = nvmeIOCmd->PRP1[0] & 0xFFFU;
    firstBytes = 0x1000U - prp1Offset;
    if (firstBytes > payloadBytes)
        firstBytes = payloadBytes;

    secondBytes = payloadBytes - firstBytes;
    if (secondBytes != 0)
    {
        /*
         * Since the whole DSM payload is <= 4 KiB, PRP2 is the second data
         * page itself (not a PRP list).  NVMe requires it to be page aligned.
         * Validate it before issuing either DMA command.
         */
        if ((nvmeIOCmd->PRP2[0] & 0xFFFU) != 0)
            return -1;
    }

    set_direct_rx_dma(DSM_PAYLOAD_ADDR,
                      nvmeIOCmd->PRP1[1],
                      nvmeIOCmd->PRP1[0],
                      firstBytes);

    if (secondBytes != 0)
    {
        set_direct_rx_dma(DSM_PAYLOAD_ADDR + firstBytes,
                          nvmeIOCmd->PRP2[1],
                          nvmeIOCmd->PRP2[0],
                          secondBytes);
    }

    check_direct_rx_dma_done();
    return 0;
}

static unsigned long long DsmNamespaceBlocks(void)
{
    return (((unsigned long long)STORAGE_CAPACITY_H) << 32) |
           (unsigned long long)storageCapacity_L;
}

static void DsmComplete(NVME_COMMAND *nvmeCmd,
                        unsigned int sc,
                        unsigned int sct,
                        XTime t0)
{
    NVME_COMPLETION cpl;
    XTime t1;

    XTime_GetTime(&t1);
    dsmStats.ticks += (unsigned long long)(t1 - t0);
    exp_dsm_end();

    cpl.dword[0] = 0;
    cpl.statusField.SC = (unsigned short)sc;
    cpl.statusField.SCT = (unsigned short)sct;
    cpl.statusField.DNR = 0;
    cpl.specific = 0;

    set_auto_nvme_cpl(nvmeCmd->cmdSlotTag,
                      cpl.specific,
                      cpl.statusFieldWord);
}

/*
 * In the supplied GreedyFTL, temporary data buffers are used only by GC copy
 * requests.  Their blockingReqTail remains non-NONE until the outstanding
 * request chain drains, so this is a substantially stronger predicate than
 * the old unconditional "return 0" stub.
 */
static int DsmGcInFlight(void)
{
    unsigned int i;

    for (i = 0; i < AVAILABLE_TEMPORARY_DATA_BUFFER_ENTRY_COUNT; i++)
    {
        if (tempDataBufMapPtr->tempDataBuf[i].blockingReqTail !=
            REQ_SLOT_TAG_NONE)
            return 1;
    }

    return 0;
}

static unsigned int DsmFindDataBufEntry(unsigned int lsa)
{
    unsigned int bucket;
    unsigned int entry;

    bucket = FindDataBufHashTableEntry(lsa);
    entry = dataBufHashTablePtr->dataBufHash[bucket].headEntry;

    while (entry != DATA_BUF_NONE)
    {
        if (dataBufMapPtr->dataBuf[entry].logicalSliceAddr == lsa)
            return entry;

        entry = dataBufMapPtr->dataBuf[entry].hashNextEntry;
    }

    return DATA_BUF_NONE;
}

static void DsmDropCleanDataBufEntry(unsigned int entry)
{
    SelectiveGetFromDataBufHashList(entry);
    dataBufMapPtr->dataBuf[entry].logicalSliceAddr = LSA_NONE;
    dataBufMapPtr->dataBuf[entry].dirty = DATA_BUF_CLEAN;
    dataBufMapPtr->dataBuf[entry].hashPrevEntry = DATA_BUF_NONE;
    dataBufMapPtr->dataBuf[entry].hashNextEntry = DATA_BUF_NONE;
}

/* Bounds are checked while LSA is still 64 bit. */
static int DsmInvalidateSlice(unsigned long long lsa64)
{
    unsigned int lsa;
    unsigned int entry;

    if (lsa64 >= (unsigned long long)SLICES_PER_SSD ||
        lsa64 > 0xFFFFFFFFULL)
        return DSM_SKIP_RANGE;

    lsa = (unsigned int)lsa64;

    entry = DsmFindDataBufEntry(lsa);
    if (entry != DATA_BUF_NONE)
    {
        /*
         * A pending/dirty entry may later write the slice back.  Do not
         * invalidate underneath it.  The experiment records this as ignored.
         */
        if (dataBufMapPtr->dataBuf[entry].dirty == DATA_BUF_DIRTY ||
            dataBufMapPtr->dataBuf[entry].blockingReqTail != REQ_SLOT_TAG_NONE)
            return DSM_SKIP_BUSY;

        /* Clean + idle cache: remove stale cached data before L2P invalidation. */
        DsmDropCleanDataBufEntry(entry);
        dsmStats.cleanEvictSlices++;
    }

    if (logicalSliceMapPtr->logicalSlice[lsa].virtualSliceAddr == VSA_NONE)
        return DSM_ALREADY_UNMAPPED;

    InvalidateOldVsa(lsa);
    return DSM_INVALIDATED;
}

static void DsmAccountIgnored(unsigned long long bytes)
{
    if (bytes == 0)
        return;

    dsmStats.ignoredBytes += bytes;
    exp_on_dsm_ignored((exp_u64)bytes);
}

/* Process a validated, merged [slba, slba + nlb) interval. */
static void DsmProcessRange(unsigned long long slba,
                            unsigned long long nlb)
{
    const unsigned long long blocksPerSlice =
        (unsigned long long)NVME_BLOCKS_PER_SLICE;
    const unsigned long long sliceBytes =
        blocksPerSlice * (unsigned long long)BYTES_PER_NVME_BLOCK;
    unsigned long long end;
    unsigned long long firstSlice;
    unsigned long long lastSlice;
    unsigned long long fullBlocks;
    unsigned long long partialBlocks;
    unsigned long long lsa;

    if (nlb == 0)
        return;

    /* This addition is safe because the caller validated nlb <= NSZE-slba. */
    end = slba + nlb;

    /* ceil(slba / blocksPerSlice), without addition-overflow tricks. */
    firstSlice = slba / blocksPerSlice;
    if ((slba % blocksPerSlice) != 0)
        firstSlice++;

    /* Exclusive full-slice upper bound. */
    lastSlice = end / blocksPerSlice;

    if (lastSlice > firstSlice)
        fullBlocks = (lastSlice - firstSlice) * blocksPerSlice;
    else
        fullBlocks = 0;

    partialBlocks = nlb - fullBlocks;
    DsmAccountIgnored(partialBlocks *
                      (unsigned long long)BYTES_PER_NVME_BLOCK);

    for (lsa = firstSlice; lsa < lastSlice; lsa++)
    {
        switch (DsmInvalidateSlice(lsa))
        {
        case DSM_INVALIDATED:
            dsmStats.invalidSlices++;
            dsmStats.invalidBytes += sliceBytes;
            exp_on_dsm_invalidated((exp_u64)sliceBytes);
            break;

        case DSM_ALREADY_UNMAPPED:
            dsmStats.unmappedSlices++;
            exp_on_dsm_already_free((exp_u64)sliceBytes);
            break;

        case DSM_SKIP_BUSY:
            dsmStats.busySkipSlices++;
            DsmAccountIgnored(sliceBytes);
            break;

        case DSM_SKIP_RANGE:
        default:
            dsmStats.errors++;
            DsmAccountIgnored(sliceBytes);
            break;
        }
    }
}

static void DsmSortRanges(unsigned int count)
{
    unsigned int i;

    for (i = 1; i < count; i++)
    {
        DSM_NORMALIZED_RANGE key = dsmRanges[i];
        unsigned int j = i;

        while (j > 0 && dsmRanges[j - 1].slba > key.slba)
        {
            dsmRanges[j] = dsmRanges[j - 1];
            j--;
        }
        dsmRanges[j] = key;
    }
}

/* Merge overlapping and directly adjacent ranges in place. */
static unsigned int DsmMergeRanges(unsigned int count)
{
    unsigned int i;
    unsigned int out;

    if (count == 0)
        return 0;

    DsmSortRanges(count);
    out = 1;

    for (i = 1; i < count; i++)
    {
        DSM_NORMALIZED_RANGE *prev = &dsmRanges[out - 1];
        unsigned long long prevEnd = prev->slba + prev->nlb;
        unsigned long long curEnd = dsmRanges[i].slba + dsmRanges[i].nlb;

        if (dsmRanges[i].slba <= prevEnd)
        {
            if (curEnd > prevEnd)
                prev->nlb = curEnd - prev->slba;
        }
        else
        {
            dsmRanges[out++] = dsmRanges[i];
        }
    }

    return out;
}

void HandleDatasetManagement(NVME_COMMAND *nvmeCmd)
{
    NVME_IO_COMMAND *nvmeIOCmd;
    DATASET_MANAGEMENT_RANGE *payload;
    XTime t0;
    unsigned long long nsBlocks;
    unsigned long long totalReqBytes;
    unsigned int cdw10;
    unsigned int cdw11;
    unsigned int nr;
    unsigned int ad;
    unsigned int i;
    unsigned int validRangeCount;
    unsigned int mergedCount;
    unsigned int payloadBytes;
    int badRange;

    nvmeIOCmd = (NVME_IO_COMMAND *)nvmeCmd->cmdDword;
    cdw10 = nvmeIOCmd->dword[10];
    cdw11 = nvmeIOCmd->dword[11];

    /* NR is zero-based: 0 means one 16-byte range descriptor. */
    nr = (cdw10 & 0xFFU) + 1U;
    ad = (cdw11 >> 2) & 0x1U;

    XTime_GetTime(&t0);
    exp_dsm_begin();
    dsmStats.cmdCount++;

    if (nvmeIOCmd->NSID != DSM_SUPPORTED_NSID)
    {
        dsmStats.invalidNsidCmds++;
        dsmStats.errors++;
        exp_on_dsm_cmd((exp_u32)nr, 0);
        DsmComplete(nvmeCmd,
                    SC_INVALID_NAMESPACE_OR_FORMAT,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    if (nr == 0 || nr > DSM_MAX_RANGES)
    {
        dsmStats.errors++;
        exp_on_dsm_cmd((exp_u32)nr, 0);
        DsmComplete(nvmeCmd,
                    SC_INVALID_FIELD_IN_COMMAND,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    /* IDR/IDW-only DSM command: accepted, but no Deallocate state change. */
    if (ad == 0)
    {
        exp_on_dsm_cmd((exp_u32)nr, 0);
        DsmComplete(nvmeCmd,
                    SC_SUCCESSFUL_COMPLETION,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    /*
     * Verify that the reserved uncached page cannot overlap the cached FTL
     * tables.  This is a firmware-layout invariant, not a host input check.
     */
    if ((unsigned long long)DSM_PAYLOAD_ADDR +
            (unsigned long long)DSM_PAYLOAD_BYTES >
        (unsigned long long)DATA_BUFFER_MAP_ADDR)
    {
        dsmStats.errors++;
        exp_on_dsm_cmd((exp_u32)nr, 0);
        DsmComplete(nvmeCmd,
                    SC_INTERNAL_DEVICE_ERROR,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    payloadBytes = nr * (unsigned int)sizeof(DATASET_MANAGEMENT_RANGE);
    if (DsmReceivePayload(nvmeIOCmd, payloadBytes) != 0)
    {
        dsmStats.errors++;
        exp_on_dsm_cmd((exp_u32)nr, 0);
        DsmComplete(nvmeCmd,
                    SC_INVALID_FIELD_IN_COMMAND,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    payload = (DATASET_MANAGEMENT_RANGE *)DSM_PAYLOAD_ADDR;
    nsBlocks = DsmNamespaceBlocks();
    totalReqBytes = 0;
    validRangeCount = 0;
    badRange = 0;

    /*
     * Validation pass: do not mutate the FTL until every descriptor has been
     * validated.  This prevents a late bad descriptor from causing partial
     * command effects.
     */
    for (i = 0; i < nr; i++)
    {
        unsigned long long slba;
        unsigned long long nlb;

        slba = ((unsigned long long)payload[i].startingLBA[1] << 32) |
               (unsigned long long)payload[i].startingLBA[0];
        nlb = (unsigned long long)payload[i].lengthInLogicalBlocks;

        totalReqBytes += nlb *
                         (unsigned long long)BYTES_PER_NVME_BLOCK;

        if (nlb == 0)
            continue;

        /* subtraction form avoids slba + nlb wraparound */
        if (slba >= nsBlocks || nlb > (nsBlocks - slba))
        {
            dsmStats.outOfRangeRanges++;
            badRange = 1;
            continue;
        }

        dsmRanges[validRangeCount].slba = slba;
        dsmRanges[validRangeCount].nlb = nlb;
        validRangeCount++;
    }

    dsmStats.rangeCount += nr;
    dsmStats.reqBytes += totalReqBytes;
    exp_on_dsm_cmd((exp_u32)nr, (exp_u64)totalReqBytes);

    if (badRange)
    {
        dsmStats.errors++;
        DsmComplete(nvmeCmd,
                    SC_LBA_OUT_OF_RANGE,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    if (DsmGcInFlight())
    {
        /* Safe, measurable fallback: do not race a GC copy chain. */
        dsmStats.gcBusyCmds++;
        DsmAccountIgnored(totalReqBytes);
        DsmComplete(nvmeCmd,
                    SC_SUCCESSFUL_COMPLETION,
                    SCT_GENERIC_COMMAND_STATUS,
                    t0);
        return;
    }

    mergedCount = DsmMergeRanges(validRangeCount);
    dsmStats.mergedRangeCount += mergedCount;

    for (i = 0; i < mergedCount; i++)
        DsmProcessRange(dsmRanges[i].slba, dsmRanges[i].nlb);

    DsmComplete(nvmeCmd,
                SC_SUCCESSFUL_COMPLETION,
                SCT_GENERIC_COMMAND_STATUS,
                t0);
}

void DsmResetStats(void)
{
    unsigned int i;
    unsigned char *p = (unsigned char *)&dsmStats;

    for (i = 0; i < sizeof(dsmStats); i++)
        p[i] = 0;
}

#define DSM_PRINT64(name, value) \
    xil_printf("DSM %s = %u%09u\r\n", \
        (name), \
        (unsigned int)((value) / 1000000000ULL), \
        (unsigned int)((value) % 1000000000ULL))

void DsmPrintStats(void)
{
    xil_printf("DSM impl_version = %u\r\n", DSM_IMPL_VERSION);
    DSM_PRINT64("cmd",          dsmStats.cmdCount);
    DSM_PRINT64("range",        dsmStats.rangeCount);
    DSM_PRINT64("merged_range", dsmStats.mergedRangeCount);
    DSM_PRINT64("req_bytes",    dsmStats.reqBytes);
    DSM_PRINT64("inval_slc",    dsmStats.invalidSlices);
    DSM_PRINT64("inval_B",      dsmStats.invalidBytes);
    DSM_PRINT64("unmapped",     dsmStats.unmappedSlices);
    DSM_PRINT64("ignored_B",    dsmStats.ignoredBytes);
    DSM_PRINT64("busy_skip",    dsmStats.busySkipSlices);
    DSM_PRINT64("clean_evict",  dsmStats.cleanEvictSlices);
    DSM_PRINT64("gc_busy_cmd",  dsmStats.gcBusyCmds);
    DSM_PRINT64("bad_nsid",     dsmStats.invalidNsidCmds);
    DSM_PRINT64("oor_range",    dsmStats.outOfRangeRanges);
    DSM_PRINT64("ticks",        dsmStats.ticks);
    DSM_PRINT64("errors",       dsmStats.errors);
}
