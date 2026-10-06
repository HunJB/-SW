/*
 * dsm_deallocate.h
 * NVMe Dataset Management (Deallocate) support for Cosmos+ OpenSSD.
 *
 * The command is called from handle_nvme_io_cmd() in nvme_io_cmd.c.
 * Counters live in exp_stat (g_exp_stat); this module keeps no statistics
 * of its own.
 */
#ifndef DSM_DEALLOCATE_H_
#define DSM_DEALLOCATE_H_

#include "nvme.h"

/* NR is an 8-bit zero-based field, so one command carries at most 256 ranges
 * (256 x 16 bytes = 4KB). */
#define DSM_MAX_RANGES			256

/* Where the range list is received. Uncached region, shared with admin
 * commands. Commands are handled one at a time, so sharing is safe. */
#ifndef DSM_PAYLOAD_BUFFER_ADDR
#define DSM_PAYLOAD_BUFFER_ADDR		ADMIN_CMD_DRAM_DATA_BUFFER
#endif

/* How the range list is fetched from the host.
 *   0: direct DMA with an explicit length, using PRP1/PRP2 (default).
 *      Same primitive the admin commands use.
 *   1: auto DMA by command slot, one 4KB unit. Try this only if the direct
 *      path does not work on the board. */
#ifndef DSM_PAYLOAD_USE_AUTO_DMA
#define DSM_PAYLOAD_USE_AUTO_DMA	0
#endif

void HandleDatasetManagement(NVME_COMMAND *nvmeCmd);

#endif /* DSM_DEALLOCATE_H_ */
