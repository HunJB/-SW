/*
 * exp_stat.h
 * Measurement counters for the Cosmos+ OpenSSD firmware
 * (discard policy vs. garbage collection experiment)
 *
 * Adding this file alone measures nothing. Each exp_on_*() call has to be
 * placed at the matching point of the firmware (see docs/INTEGRATION.md).
 *
 *  - Every counter is a 64-bit running total. Use the difference between the
 *    start and the end of a measurement instead of resetting.
 *  - Nothing is printed per page. UART output happens at boot, on shutdown,
 *    on the marker command, and periodically only if the period is not 0.
 *  - Units are bytes (or counts, timer ticks). Callers convert pages/slices.
 *  - The host reads the counters with the vendor admin command 0xC2
 *    (4KB binary snapshot). tools/parse_expstat.py decodes it.
 *
 * Only the NVMe main loop updates these counters (no ISR, no second core).
 */
#ifndef EXP_STAT_H_
#define EXP_STAT_H_

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned long long exp_u64;
typedef unsigned int       exp_u32;

/* ---------- configuration ---------- */

/* Period of the UART dump in seconds. 0 = off.
 * One line takes about 40 ms at 115200 bps and blocks the firmware meanwhile,
 * which shows up in the host read p99. Keep it 0 for latency measurements and
 * use the snapshot command. Set it to 10 only for UART-based checks. */
#ifndef EXP_STAT_PRINT_PERIOD_SEC
#define EXP_STAT_PRINT_PERIOD_SEC 0
#endif

/* vendor specific admin opcodes */
#define EXP_ADMIN_OPC_MARKER    0xC0   /* print one UART line. cdw10 = 1: reset afterwards */
#define EXP_ADMIN_OPC_SNAPSHOT  0xC2   /* return counters to the host in a 4KB buffer */

#define EXP_SNAPSHOT_MAGIC      0x3354415453505845ULL   /* "EXPSTAT3" (little endian) */
#define EXP_SNAPSHOT_BYTES      4096
#define EXP_SNAPSHOT_HEADER_NR  4      /* magic, tick, counts per second, number of fields */

/* per-command DSM histograms (log2 buckets) */
#define EXP_HIST_TICKS_NR       40     /* bucket i: 2^i <= handling time in ticks < 2^(i+1) */
#define EXP_HIST_LBA_NR         32     /* bucket i: 2^i <= requested 4KB blocks < 2^(i+1) */

/* cause of a NAND program */
typedef enum {
    EXP_PROG_HOST = 0,   /* program of host data (data buffer eviction) */
    EXP_PROG_GC   = 1,   /* program of valid data copied by GC */
    EXP_PROG_META = 2,   /* any other program (bad block table, ...) */
    EXP_PROG_NR
} exp_prog_cause_t;

/* ---------- counters ----------
 * All fields are exp_u64: the snapshot copies the struct as an array.
 * Append new fields at the end only, and add the same name at the same place
 * in tools/parse_expstat.py (tests/host checks the order). */
typedef struct {
    /* host write bytes (NVMe write command accepted) */
    exp_u64 host_write_bytes;
    exp_u64 host_write_cmds;

    /* bytes of valid data GC decided to copy (request issue time) */
    exp_u64 gc_copy_bytes;

    /* GC victims whose copy/erase requests were all issued (not completed) */
    exp_u64 gc_count;
    exp_u64 gc_victim_valid_bytes;   /* valid bytes found in those victims */

    /* block erases */
    exp_u64 erase_issued;            /* erase requests handed to the NAND driver */
    exp_u64 erase_count;             /* completed erases (not tracked in this build) */
    exp_u64 erase_fail;

    /* Dataset Management commands received */
    exp_u64 dsm_cmd_count;
    exp_u64 dsm_range_count;
    exp_u64 dsm_req_bytes;           /* total bytes requested by the host */

    /* result of Deallocate */
    exp_u64 dsm_invalid_bytes;       /* was valid, now invalidated */
    exp_u64 dsm_ignored_bytes;       /* not applied: partial slice, busy buffer entry, GC in flight */
    exp_u64 dsm_already_free_bytes;  /* already unmapped or never written */

    /* time spent handling DSM commands, in timer ticks */
    exp_u64 dsm_ticks_total;
    exp_u64 dsm_ticks_max;

    /* NAND program bytes by cause, for WAF */
    exp_u64 nand_prog_bytes[EXP_PROG_NR];

    /* self check */
    exp_u64 dsm_nesting_error;       /* end without begin, or nested begin */
    exp_u64 epoch;                   /* incremented on every reset */
    exp_u64 dump_seq;                /* UART dump sequence number */

    /* --- added for snapshot schema 3. Append below, never reorder. --- */
    exp_u64 dsm_hist_ticks[EXP_HIST_TICKS_NR];   /* per-command handling time */
    exp_u64 dsm_hist_lba[EXP_HIST_LBA_NR];       /* per-command requested size */
} exp_stat_t;

extern exp_stat_t g_exp_stat;

/* ---------- init and output ---------- */

/* call once after InitFTL() */
void exp_stat_init(void);

/* zero every counter (epoch and dump_seq are kept). Prefer differences. */
void exp_stat_reset(void);

/* print the current values to UART in one line. tag: "PERIOD", "MARK", "BOOT", ... */
void exp_stat_dump(const char *tag);

/* call from the main loop. Dumps when the period elapsed (no-op if period is 0) */
void exp_stat_poll(void);

/* marker command from the host: arg = 0 print only, arg = 1 print then reset */
void exp_stat_on_marker(exp_u32 arg);

/* write the counters to buf in binary and return the bytes used.
 *   u64 magic, u64 tick, u64 counts_per_second, u64 nfields, exp_stat_t
 * The caller may append more sections after the returned length. */
exp_u32 exp_stat_snapshot(void *buf);

/* ---------- calls placed in the firmware ---------- */

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

/* once per accepted NVMe write command. bytes = (NLB + 1) * LBA size */
static inline void exp_on_host_write(exp_u64 bytes)
{
    g_exp_stat.host_write_cmds++;
    g_exp_stat.host_write_bytes += bytes;
}

/* once per valid slice GC decides to move (write side only) */
static inline void exp_on_gc_copy(exp_u64 bytes)
{
    g_exp_stat.gc_copy_bytes += bytes;
}

/* once per victim, after all its copy/erase requests were issued */
static inline void exp_on_gc_victim_scheduled(exp_u64 victim_valid_bytes)
{
    g_exp_stat.gc_count++;
    g_exp_stat.gc_victim_valid_bytes += victim_valid_bytes;
}

/* only where the completion status is really known (not wired in this build) */
static inline void exp_on_erase(int ok)
{
    if (ok) g_exp_stat.erase_count++;
    else    g_exp_stat.erase_fail++;
}

static inline void exp_on_erase_issued(void)
{
    g_exp_stat.erase_issued++;
}

/* one NAND program request handed to the driver */
static inline void exp_on_nand_program(exp_prog_cause_t cause, exp_u64 bytes)
{
    if ((unsigned)cause < EXP_PROG_NR)
        g_exp_stat.nand_prog_bytes[cause] += bytes;
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

/* requested bytes that were not applied */
static inline void exp_on_dsm_ignored(exp_u64 bytes)
{
    g_exp_stat.dsm_ignored_bytes += bytes;
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
