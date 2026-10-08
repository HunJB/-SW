/*
 * exp_stat.c
 * Cosmos+ OpenSSD 펌웨어용 실험 계측 모듈 구현
 *
 * Zynq-7000 standalone BSP 기준
 *  - 시간: xtime_l.h 의 XTime_GetTime() (Cortex-A9 global timer)
 *  - 출력: xil_printf. xil_printf는 %llu 를 지원하지 않으므로
 *          64비트 값은 직접 10진 문자열로 바꿔 %s 로 출력한다.
 *
 * PC에서 컴파일 검사만 할 때는 -DEXP_STAT_HOST_TEST 로 빌드한다.
 */
#include "exp_stat.h"

#ifdef EXP_STAT_HOST_TEST
  #include <stdio.h>
  #include <time.h>
  typedef exp_u64 XTime;
  #define COUNTS_PER_SECOND 1000000000ULL
  static void XTime_GetTime(XTime *t)
  {
      struct timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      *t = (XTime)ts.tv_sec * 1000000000ULL + (XTime)ts.tv_nsec;
  }
  #define xil_printf printf
#else
  #include "xil_printf.h"
  #include "xtime_l.h"
#endif

exp_stat_t g_exp_stat;

static XTime s_last_print;
static XTime s_dsm_start;
static int   s_dsm_active;

/* ---------- 내부 도우미 ---------- */

static void u64_to_dec(exp_u64 v, char *buf)
{
    char tmp[21];
    int  n = 0, i;

    if (v == 0) {
        buf[0] = '0';
        buf[1] = '\0';
        return;
    }
    while (v > 0 && n < 20) {
        tmp[n++] = (char)('0' + (v % 10ULL));
        v /= 10ULL;
    }
    for (i = 0; i < n; i++)
        buf[i] = tmp[n - 1 - i];
    buf[n] = '\0';
}

static void print_kv(const char *key, exp_u64 v)
{
    char buf[21];
    u64_to_dec(v, buf);
    xil_printf(",%s=%s", key, buf);
}

static void zero_counters(void)
{
    unsigned char *p = (unsigned char *)&g_exp_stat;
    unsigned int i;
    exp_u64 epoch = g_exp_stat.epoch;
    exp_u64 seq = g_exp_stat.dump_seq;   /* 일련번호는 리셋해도 이어지게 */

    for (i = 0; i < sizeof(g_exp_stat); i++)
        p[i] = 0;
    g_exp_stat.dump_seq = seq;
    g_exp_stat.epoch = epoch;
}

/* ---------- 공개 함수 ---------- */

void exp_stat_init(void)
{
    g_exp_stat.dump_seq = 0;
    g_exp_stat.epoch = 0;
    zero_counters();
    s_dsm_active = 0;
    XTime_GetTime(&s_last_print);
    exp_stat_dump("BOOT");
}

void exp_stat_reset(void)
{
    g_exp_stat.epoch++;
    zero_counters();
    s_dsm_active = 0;
}

/*
 * 출력 형식 (한 줄):
 *   EXPSTAT,tag=MARK,seq=3,tick=...,cps=...,host_wr_B=...,...
 * 호스트에서 parse_expstat.py 로 CSV로 바꾼다.
 */
void exp_stat_dump(const char *tag)
{
    XTime now;
    exp_stat_t *s = &g_exp_stat;

    XTime_GetTime(&now);
    s->dump_seq++;

    xil_printf("\r\nEXPSTAT,tag=%s", tag);
    xil_printf(",schema=2,basis=request_issue,dsm_supported=1,erase_completion_tracked=0");
    print_kv("epoch", s->epoch);
    print_kv("seq", s->dump_seq);
    print_kv("tick", (exp_u64)now);
    print_kv("cps", (exp_u64)COUNTS_PER_SECOND);

    print_kv("host_wr_B", s->host_write_bytes);
    print_kv("host_wr_cmd", s->host_write_cmds);

    print_kv("gc_copy_B", s->gc_copy_bytes);
    print_kv("gc_scheduled", s->gc_count);
    print_kv("gc_victim_valid_B", s->gc_victim_valid_bytes);

    print_kv("erase_issued", s->erase_issued);
    print_kv("erase_cnt", s->erase_count);
    print_kv("erase_fail", s->erase_fail);

    print_kv("prog_host_B", s->nand_prog_bytes[EXP_PROG_HOST]);
    print_kv("prog_gc_B", s->nand_prog_bytes[EXP_PROG_GC]);
    print_kv("prog_meta_B", s->nand_prog_bytes[EXP_PROG_META]);

    print_kv("dsm_cmd", s->dsm_cmd_count);
    print_kv("dsm_range", s->dsm_range_count);
    print_kv("dsm_req_B", s->dsm_req_bytes);
    print_kv("dsm_inval_B", s->dsm_invalid_bytes);
    print_kv("dsm_ignored_B", s->dsm_ignored_bytes);
    print_kv("dsm_already_free_B", s->dsm_already_free_bytes);
    print_kv("dsm_ticks", s->dsm_ticks_total);
    print_kv("dsm_ticks_max", s->dsm_ticks_max);

    print_kv("dsm_nest_err", s->dsm_nesting_error);
    xil_printf("\r\n");

    s_last_print = now;
}

void exp_stat_poll(void)
{
#if EXP_STAT_PRINT_PERIOD_SEC > 0
    XTime now;
    XTime_GetTime(&now);
    if ((exp_u64)(now - s_last_print) >=
        (exp_u64)EXP_STAT_PRINT_PERIOD_SEC * (exp_u64)COUNTS_PER_SECOND) {
        exp_stat_dump("PERIOD");
    }
#endif
}

void exp_stat_on_marker(exp_u32 arg)
{
    exp_stat_dump("MARK");
    if (arg == 1)
        exp_stat_reset();
}

void exp_dsm_begin(void)
{
    if (s_dsm_active) {
        g_exp_stat.dsm_nesting_error++;
        return;
    }
    s_dsm_active = 1;
    XTime_GetTime(&s_dsm_start);
}

void exp_dsm_end(void)
{
    XTime now;
    exp_u64 d;

    if (!s_dsm_active) {
        g_exp_stat.dsm_nesting_error++;
        return;
    }
    XTime_GetTime(&now);
    d = (exp_u64)(now - s_dsm_start);
    g_exp_stat.dsm_ticks_total += d;
    if (d > g_exp_stat.dsm_ticks_max)
        g_exp_stat.dsm_ticks_max = d;
    s_dsm_active = 0;
}
