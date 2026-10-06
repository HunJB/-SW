/*
 * exp_stat.h
 * Measurement counters for the Cosmos+ OpenSSD firmware
 * (discard policy vs. garbage collection experiment)
 *
 * Adding this file alone measures nothing. Each exp_on_*() call has to be
 * placed at the matching point of the firmware. See INTEGRATION.md.
 *
 *  - Every counter is a 64-bit running total. Use the difference between
 *    the start and the end of a measurement.
 *  - Nothing is printed per page. Output happens only on a host command.
 *  - Units are bytes (or counts, timer ticks). Callers convert slices to bytes.
 */
#ifndef EXP_STAT_H_
#define EXP_STAT_H_

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long long exp_u64;
typedef unsigned int       exp_u32;

/* ---------- configuration ---------- */

/* Period of the UART dump in seconds. Default 0 (off).
 * One line (about 450 chars) takes close to 40ms at 115200bps and the firmware
 * is blocked meanwhile, which would pollute p99 latency. Use the snapshot
 * command (0xC2) during measurements. */
#ifndef EXP_STAT_PRINT_PERIOD_SEC
#define EXP_STAT_PRINT_PERIOD_SEC 0
#endif

/* vendor specific admin opcodes sent by the host */
#define EXP_ADMIN_OPC_MARKER    0xC0   /* print one line to UART. cdw10 = 1: reset afterwards */
#define EXP_ADMIN_OPC_SNAPSHOT  0xC2   /* return counters to the host in a 4KB buffer */

#define EXP_SNAPSHOT_MAGIC      0x3254415453505845ULL   /* "EXPSTAT2" (little endian) */
#define EXP_SNAPSHOT_BYTES      4096
#define EXP_SNAPSHOT_HEADER_NR  4      /* magic, tick, counts per second, number of fields */

/* histogram sizes (log2 buckets, one count per DSM command) */
#define EXP_HIST_TICKS_NR       40     /* bucket i: 2^i <= handling time in timer ticks < 2^(i+1) */
#define EXP_HIST_LBA_NR         32     /* bucket i: 2^i <= requested 4KB blocks < 2^(i+1) */

/* cause of a NAND program */
typedef enum {
    EXP_PROG_HOST = 0,   /* program caused by host write */
    EXP_PROG_GC   = 1,   /* program caused by GC valid data copy */
    EXP_PROG_META = 2,   /* metadata program (unused in this FTL) */
    EXP_PROG_NR
} exp_prog_cause_t;

/* ---------- counters (all 64-bit, keep it that way: snapshot copies it as u64[]) ---------- */
typedef struct {
    /* host write bytes (NVMe write command) */
    exp_u64 host_write_bytes;
    exp_u64 host_write_cmds;

    /* bytes of valid data copied by GC */
    exp_u64 gc_copy_bytes;

    /* number of GC victims reclaimed */
    exp_u64 gc_count;
    exp_u64 gc_victim_valid_bytes;   /* valid bytes found in the reclaimed victims */

    /* block erases */
    exp_u64 erase_count;
    exp_u64 erase_fail;

    /* Dataset Management commands received */
    exp_u64 dsm_cmd_count;
    exp_u64 dsm_range_count;
    exp_u64 dsm_req_bytes;           /* total bytes requested by the host */

    /* bytes newly invalidated by Deallocate */
    exp_u64 dsm_invalid_bytes;       /* was valid, now invalidated */
    exp_u64 dsm_ignored_bytes;       /* ignored (partial slice, out of range) */
    exp_u64 dsm_already_free_bytes;  /* already unmapped or never written */

    /* time spent handling DSM commands, in timer ticks */
    exp_u64 dsm_ticks_total;
    exp_u64 dsm_ticks_max;

    /* NAND program bytes by cause, for WAF */
    exp_u64 nand_prog_bytes[EXP_PROG_NR];

    /* self check */
    exp_u64 dsm_nesting_error;       /* end without begin, or nested begin */
    exp_u64 dump_seq;                /* dump sequence number */

    /* --- added in snapshot version 2. Append new fields below, never reorder. --- */
    exp_u64 dsm_busy_skip_bytes;     /* slice still in the DRAM data buffer, left mapped */
    exp_u64 dsm_error_count;         /* command completed without touching the map (bad payload address) */
    exp_u64 dsm_hist_ticks[EXP_HIST_TICKS_NR];   /* per-command handling time */
    exp_u64 dsm_hist_lba[EXP_HIST_LBA_NR];       /* per-command requested size */
} exp_stat_t;

extern exp_stat_t g_exp_stat;

/* ---------- init and output ---------- */

/* call once after FTL init */
void exp_stat_init(void);

/* zero every counter. Prefer differences over resets */
void exp_stat_reset(void);

/* print the current values to UART in one line. tag: "PERIOD", "MARK", "BOOT" */
void exp_stat_dump(const char *tag);

/* call from the main loop. Dumps when the period elapsed (no-op if period is 0) */
void exp_stat_poll(void);

/* marker command from the host: arg = 0 print only, arg = 1 print then reset */
void exp_stat_on_marker(exp_u32 arg);

/* write the counters to buf (4KB) in binary. Returns the bytes used.
 *   u64 magic, u64 tick, u64 counts_per_second, u64 nfields, then exp_stat_t (nfields x u64).
 * tools/parse_expstat.py lists the field names in the same order. */
exp_u32 exp_stat_snapshot(void *buf);

/* ---------- calls to place in the firmware ---------- */

/* once per accepted NVMe write command. bytes = (NLB + 1) * LBA size */
static inline void exp_on_host_write(exp_u64 bytes)
{
    g_exp_stat.host_write_cmds++;
    g_exp_stat.host_write_bytes += bytes;
}

/* once per valid slice GC decides to move.
 * Do not call it for both the read and the write request of the same slice */
static inline void exp_on_gc_copy(exp_u64 bytes)
{
    g_exp_stat.gc_copy_bytes += bytes;
}

/* once per victim block, after its valid data has been queued for copy */
static inline void exp_on_gc_victim_done(exp_u64 victim_valid_bytes)
{
    g_exp_stat.gc_count++;
    g_exp_stat.gc_victim_valid_bytes += victim_valid_bytes;
}

/* one block erase. Pass ok = 1 when the result is not known yet */
static inline void exp_on_erase(int ok)
{
    if (ok) g_exp_stat.erase_count++;
    else    g_exp_stat.erase_fail++;
}

/* one NAND program */
static inline void exp_on_nand_program(exp_prog_cause_t cause, exp_u64 bytes)
{
    if ((unsigned)cause < EXP_PROG_NR)
        g_exp_stat.nand_prog_bytes[cause] += bytes;
}

/* floor(log2(v)), 0 for v <= 1, capped at nr - 1 */
static inline unsigned int exp_log2_bucket(exp_u64 v, unsigned int nr)
{
    unsigned int b = 0;
    while (v > 1) {
        v >>= 1;
        b++;
    }
    return (b < nr) ? b : (nr - 1);
}

/* once per DSM command (counted even without the Deallocate attribute) */
static inline void exp_on_dsm_cmd(exp_u32 nranges, exp_u64 req_bytes)
{
    g_exp_stat.dsm_cmd_count++;
    g_exp_stat.dsm_range_count += nranges;
    g_exp_stat.dsm_req_bytes += req_bytes;
    g_exp_stat.dsm_hist_lba[exp_log2_bucket(req_bytes / 4096ULL, EXP_HIST_LBA_NR)]++;
}

/* a slice that was valid has been invalidated */
static inline void exp_on_dsm_invalidated(exp_u64 bytes)
{
    g_exp_stat.dsm_invalid_bytes += bytes;
}

/* ignored bytes */
static inline void exp_on_dsm_ignored(exp_u64 bytes)
{
    g_exp_stat.dsm_ignored_bytes += bytes;
}

/* slice skipped because it is still in the DRAM data buffer */
static inline void exp_on_dsm_busy_skip(exp_u64 bytes)
{
    g_exp_stat.dsm_busy_skip_bytes += bytes;
}

/* command that could not be processed */
static inline void exp_on_dsm_error(void)
{
    g_exp_stat.dsm_error_count++;
}

/* slice already unmapped */
static inline void exp_on_dsm_already_free(exp_u64 bytes)
{
    g_exp_stat.dsm_already_free_bytes += bytes;
}

/* DSM handling time. Call begin at the start and end on every return path */
void exp_dsm_begin(void);
void exp_dsm_end(void);

#ifdef __cplusplus
}
#endif

#endif /* EXP_STAT_H_ */
