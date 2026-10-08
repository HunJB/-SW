/*
 * dsm_deallocate.h
 * NVMe Dataset Management (Deallocate) support for Cosmos+ OpenSSD.
 *
 * This version is intended for the GreedyFTL source tree used by the
 * discard/GC experiment.  It validates NSID/LBA ranges before changing the
 * FTL map and feeds the existing exp_stat instrumentation.
 */
#ifndef DSM_DEALLOCATE_H_
#define DSM_DEALLOCATE_H_

#include "nvme.h"

#define DSM_IMPL_VERSION            3U
#define DSM_SUPPORTED_NSID          1U
#define DSM_MAX_RANGES              256U
#define DSM_PAYLOAD_BYTES           (DSM_MAX_RANGES * sizeof(DATASET_MANAGEMENT_RANGE))

/* All fields are unsigned long long: DsmSnapshot() copies the struct as an
 * array. Append new fields at the end and add the name to
 * tools/parse_expstat.py (DSM_FIELDS) in the same place. */
typedef struct _DSM_STATS
{
    unsigned long long cmdCount;
    unsigned long long rangeCount;
    unsigned long long mergedRangeCount;
    unsigned long long reqBytes;

    unsigned long long invalidSlices;
    unsigned long long invalidBytes;
    unsigned long long unmappedSlices;
    unsigned long long ignoredBytes;

    unsigned long long busySkipSlices;
    unsigned long long cleanEvictSlices;
    unsigned long long gcBusyCmds;

    unsigned long long invalidNsidCmds;
    unsigned long long outOfRangeRanges;
    unsigned long long errors;

    unsigned long long ticks;
} DSM_STATS;

extern DSM_STATS dsmStats;

void HandleDatasetManagement(NVME_COMMAND *nvmeCmd);
void DsmPrintStats(void);
void DsmResetStats(void);

/* Append the DSM statistics to a host snapshot (vendor admin 0xC2).
 * Layout: u64 number of fields, then DSM_STATS as u64[]. Returns bytes written. */
unsigned int DsmSnapshot(void *buf, unsigned int maxBytes);

#endif /* DSM_DEALLOCATE_H_ */
