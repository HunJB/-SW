/*
 * ftl_instrumentation.c
 *
 * FEMU의 FTL(예: bb_ftl.c, 혹은 사용 중인 FTL 소스 파일)에 끼워넣을
 * "GC 복사 이벤트"와 "discard(Deallocate) 도착 이벤트" 계측 코드 템플릿.
 *
 * 실제 FEMU 소스의 함수명/구조체명은 커밋마다 다르므로, 아래 TODO 표시된
 * 부분을 본인이 쓰는 FEMU 버전의 실제 코드에 맞춰 수정해서 삽입하세요.
 *
 * 설계 원칙 (연구 PDF 기준):
 *   - GC가 "페이지를 옮기는 시점"마다 LBA + timestamp 기록
 *   - discard(Deallocate)가 "도착해서 매핑을 해제하는 시점"마다 LBA + timestamp 기록
 *   - 매 페이지마다 printf 하지 않는다 (지연에 영향을 주므로) → 메모리 버퍼에
 *     쌓았다가 실행 종료 시 한 번에 CSV로 flush
 */

#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <string.h>

/* ---------- 설정 ---------- */
#define IO_LOG_MAX_EVENTS   (1 << 22)   /* 필요에 따라 조정 (event 수 추정치 x 1.5 정도 권장) */
#define IO_LOG_OUT_PATH     "/tmp/femu_ftl_log"  /* run_experiment.sh가 이 경로를 복사해감 */

typedef enum {
    EVT_GC_COPY = 0,
    EVT_DISCARD_ARRIVE = 1,
} io_log_event_type_t;

typedef struct {
    uint64_t device_tick_ns;   /* FEMU 내부 틱 또는 gettimeofday 기반 ns */
    io_log_event_type_t type;
    uint64_t lba;              /* 이벤트 대상 LBA (시작 주소) */
    uint32_t length_bytes;     /* 길이 (page 단위라면 page_size) */
    uint64_t src_ppa;          /* GC_COPY일 때만 의미 있음 */
    uint64_t dst_ppa;          /* GC_COPY일 때만 의미 있음 */
} io_log_record_t;

/* 전역 링버퍼 — 실제로는 FTL 구조체 안에 넣는 걸 권장 (전역 변수는 테스트용) */
static io_log_record_t g_io_log[IO_LOG_MAX_EVENTS];
static uint64_t g_io_log_count = 0;
static uint64_t g_io_log_dropped = 0;

static inline uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static inline void io_log_push(io_log_event_type_t type, uint64_t lba,
                                uint32_t length_bytes, uint64_t src_ppa, uint64_t dst_ppa)
{
    if (g_io_log_count >= IO_LOG_MAX_EVENTS) {
        g_io_log_dropped++;
        return;
    }
    io_log_record_t *r = &g_io_log[g_io_log_count++];
    r->device_tick_ns = now_ns();
    r->type = type;
    r->lba = lba;
    r->length_bytes = length_bytes;
    r->src_ppa = src_ppa;
    r->dst_ppa = dst_ppa;
}

/*
 * 실행 종료 시(혹은 run_experiment.sh가 신호를 보낼 때) 호출해서
 * 버퍼 내용을 CSV로 저장. FEMU 종료 경로나 별도 QMP 커맨드에 연결하세요.
 */
void io_log_flush_to_csv(void)
{
    FILE *f = fopen(IO_LOG_OUT_PATH ".csv", "w");
    if (!f) return;

    fprintf(f, "tick_ns,type,lba,length_bytes,src_ppa,dst_ppa\n");
    for (uint64_t i = 0; i < g_io_log_count; i++) {
        io_log_record_t *r = &g_io_log[i];
        fprintf(f, "%llu,%d,%llu,%u,%llu,%llu\n",
                (unsigned long long)r->device_tick_ns,
                r->type,
                (unsigned long long)r->lba,
                r->length_bytes,
                (unsigned long long)r->src_ppa,
                (unsigned long long)r->dst_ppa);
    }
    fclose(f);

    FILE *meta = fopen(IO_LOG_OUT_PATH ".meta", "w");
    if (meta) {
        fprintf(meta, "logged_events=%llu\ndropped_events=%llu\n",
                (unsigned long long)g_io_log_count,
                (unsigned long long)g_io_log_dropped);
        fclose(meta);
    }
}

/* ======================================================================
 * TODO 1: GC가 valid page를 새 블록으로 복사하는 지점에 아래를 삽입
 * ======================================================================
 *
 * FEMU의 GC 관련 함수(보통 clean_one_block() / gc_write_page() 류의 이름)
 * 안에서, "valid page 하나를 src_ppa에서 dst_ppa로 복사 완료"하는 지점을
 * 찾아서 다음 호출을 추가하세요:
 *
 *   uint64_t lba = get_rmap(ftl, src_ppa);   // 역방향 매핑 함수 이름은 FTL마다 다름
 *   io_log_push(EVT_GC_COPY, lba, ftl->page_size, src_ppa, dst_ppa);
 *
 * 주의:
 *   - "GC가 victim block을 고른 시점"이 아니라 "실제로 페이지 복사가
 *     완료된 시점"에 기록해야 함 (PDF 3장 "gc_copy_bytes" 정의와 일치)
 *   - host_write로 인한 program과 GC로 인한 program을 구분해서 호출해야
 *     나중에 WAF 계산 시 원인별 분리가 가능함
 */

/* ======================================================================
 * TODO 2: NVMe Dataset Management(Deallocate) 명령이 처리되는 지점에 삽입
 * ======================================================================
 *
 * FEMU에서 DSM/Deallocate opcode를 처리하는 함수(보통
 * nvme_dsm() 또는 femu_dsm_deallocate() 류)에서, 매핑을 실제로 해제하는
 * 지점을 찾아 다음을 추가하세요:
 *
 *   for (각 range의 LBA 구간) {
 *       io_log_push(EVT_DISCARD_ARRIVE, start_lba, length_bytes, 0, 0);
 *       // 실제 L2P 매핑 invalidate 처리는 기존 로직 그대로 둠
 *   }
 *
 * 주의:
 *   - "명령을 수신한 시점"이 아니라 "L2P/valid bitmap을 실제로 갱신한
 *     시점"에 기록 (PDF 2장 "discard 명령이 도착하기 전까지는 유효한
 *     데이터로 취급한다"는 정의와 맞춰야 함)
 *   - range가 여러 개로 올 수 있으므로 range마다 개별 기록
 */

/* ======================================================================
 * TODO 3: FEMU 프로세스/게스트 종료 경로에서 io_log_flush_to_csv() 호출
 * ======================================================================
 * 가장 간단한 방법은 QEMU의 atexit 핸들러나, 실험 스크립트가 QMP로
 * "quit" 보내기 직전에 커스텀 QMP 커맨드(예: "femu-flush-log")를 추가해
 * 호출하는 것. run_experiment.sh는 이 CSV가 생성됐다고 가정하고 동작함.
 */
