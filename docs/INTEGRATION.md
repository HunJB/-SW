# 계측·Deallocate 펌웨어 적용과 검증

대상: Cosmos+ OpenSSD GreedyFTL (`src`). 펌웨어 쪽 Deallocate 구현은 팀이 보드에서 다듬은 버전(`DSM_IMPL_VERSION 3`)이고, 호스트 도구는 그 펌웨어에 맞춰져 있다.

PC에서 한 것은 문법 검사, 처리 로직 시험, 보드 동작을 흉내 낸 모형으로 검증 스크립트를 돌려 본 것까지다. 호스트 스냅샷 명령(0xC2)을 넣은 이 버전은 **보드에서 아직 빌드·실행하지 않았다.** 4절의 검증을 통과해야 측정에 쓸 수 있다.

## 1. 구성

| 위치 | 내용 |
| --- | --- |
| `src/nvme/dsm_deallocate.c`, `.h` | Dataset Management(Deallocate) 처리와 DSM 세부 통계(`DSM_STATS`) |
| `src/exp_stat.c`, `.h` | 실험 카운터, UART 출력, 호스트 스냅샷 |
| `src/nvme/nvme_admin_cmd.c` | Identify CNS 수정, 벤더 명령 0xC0(UART 출력)·0xC2(스냅샷) |
| `src`의 그 밖의 파일 | 카운터 호출 한두 줄씩 (`nvme_io_cmd.c`, `nvme_main.c`, `garbage_collection.c`, `request_schedule.c`, `nvme_identify.c`, `data_buffer.h`, `ftl_config.h`) |
| `quickstart.sh` | 보드 점검을 단계별로 실행 |
| `tests/host/` | PC에서 돌리는 로직 시험 (`make test`, `make syntax`) |
| `tools/fw_verify.sh` | 보드 검증 T0~T5 |
| `tools/parse_expstat.py` | 스냅샷 해석, 두 시점의 차이, WAF, DSM 분포. UART 로그도 읽음 |
| `tools/split_trim.sh` | Split Batch용 fstrim 분할 |
| `tools/discard_check.sh` | discard 뒤 쓰기 성능이 회복되는지 확인(장치 전체를 채우므로 오래 걸림) |
| `ssd_discard_experiment/` | 4가지 방식 측정 실행기(W1~W3)와 분석 스크립트. 자체 README 참고 |

## 2. 펌웨어가 하는 일

### Deallocate 처리 (`dsm_deallocate.c`)

1. NSID가 1이 아니거나 range 수가 범위를 벗어나면 오류로 완료한다.
2. range 목록을 길이를 지정한 direct DMA로 비캐시 영역(`TEMPORARY_PAY_LOAD_ADDR` 다음 4KB 페이지)에 받는다.
3. 모든 range를 먼저 검사한다. 하나라도 용량을 벗어나면 아무것도 바꾸지 않고 `LBA Out of Range`로 완료한다.
4. GC 복사 요청이 아직 처리 중이면(임시 버퍼가 사용 중이면) 명령 전체를 적용하지 않고 성공으로 완료한다. 이 양은 `dsm_ignored_B`와 `dsm_gc_busy_cmds`에 잡힌다.
5. 같은 명령 안의 range를 정렬해 붙어 있거나 겹치는 것을 합친다.
6. 완전히 덮인 16KB slice만 무효화한다. 그 slice가 data buffer에 있으면:
   - dirty이거나 진행 중인 요청이 있으면 건너뛴다 (`dsm_busy_slices`, `dsm_ignored_B`에 포함).
   - clean이면 캐시에서 빼고 무효화한다 (`dsm_clean_evict_slices`).

### 카운터 (`exp_stat`)

- 모든 카운터는 부팅 후 누적값이다. 측정 시작과 끝의 차이를 쓴다.
- UART에는 부팅(`BOOT`), 종료(`SHUTDOWN`), 마커 명령(`MARK`) 때 한 줄씩 나온다. 주기 출력(`PERIOD`)은 기본으로 꺼져 있다. 한 줄에 약 40ms 동안 펌웨어가 멈춰 읽기 지연을 흐리기 때문이다. UART로 확인하는 시험을 할 때만 `exp_stat.h`의 `EXP_STAT_PRINT_PERIOD_SEC`을 10으로 바꿔 빌드한다.
- 호스트는 벤더 admin 명령 0xC2로 4KB 스냅샷을 받는다. 스냅샷에는 `exp_stat_t` 전체와 `DSM_STATS` 전체가 들어 있다.
- 부팅 줄의 `schema=3`이 스냅샷 명령을 지원한다는 표시다.

## 3. 적용과 빌드

1. 지금 보드에서 쓰는 bitstream과 ELF, SDK 프로젝트의 `src` 폴더를 따로 복사해 둔다.
2. 저장소의 `src` 폴더로 SDK 프로젝트의 `src`를 교체한다. 용량은 이미 `USER_BLOCKS_PER_LUN 512`(약 14GB)로 되어 있다.
3. SDK에서 프로젝트를 새로 고침(F5)하고 Clean → Build.

빌드 전에 리눅스 PC에서 먼저 확인할 수 있다.

```bash
cd tests/host
make test      # Deallocate 처리와 카운터 시험(13가지 경우), 스냅샷 필드 순서 확인
make syntax    # 실험 때문에 손댄 펌웨어 파일 9개 문법 검사
```

## 4. 보드 검증

보드를 올린 직후 UART 부팅 줄에서 `schema=3`을 확인하고 실행한다. 장치 앞쪽 약 1.6GiB를 덮어쓴다.

```bash
sudo ./quickstart.sh                  # 단계별 안내 (권장)
# 또는 검증만:
cd tools
sudo DEV=/dev/nvme1n1 EXPECTED_SERIAL=<시리얼> ./fw_verify.sh
```

| 단계 | 확인하는 것 | 통과 기준 |
| --- | --- | --- |
| T0 | 시리얼, 마운트 여부, DSM 지원 표시, 스냅샷 명령 | ONCS에 DSM 비트, `DISC-MAX` ≠ 0, 스냅샷 해석 성공 |
| T1 | 쓰기 카운터 | 256MiB 쓰기 → `host_wr_B` = 268435456 |
| T2 | 기본 동작 | 64MiB discard → `dsm_inval_B` = 64MiB. 재요청 시 0, `dsm_already_free_B` = 64MiB. 방금 쓴 1MiB는 `dsm_busy_B`로 잡히고, buffer를 비운 뒤에는 무효화됨 |
| T3 | slice 경계 | 한 LBA 어긋난 1MiB → 63 slice만 무효화, 16KB 무시. 양쪽 slice 내용 그대로 |
| T4 | 데이터 보존 | discard하지 않은 범위 내용 유지, discard한 범위에 다시 쓴 내용 일치 |
| T5 | 동시 실행 | fio 쓰기·CRC 검증 중 다른 범위에 쓰기·discard 반복. 검증 오류 0, `dsm_errors` 0 |

한 단계라도 실패하면 스크립트가 멈춘다. 명령이 돌아오지 않으면 보드가 멈춘 것이므로 UART의 마지막 출력과 `sudo dmesg | tail -40`을 기록한다.

## 5. 측정

측정은 `ssd_discard_experiment/scripts`에서 한다. 자세한 사용법은 그 폴더의 README에 있다.

```bash
cd ssd_discard_experiment/scripts
export EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test EXPSTAT=1
sudo -E ./run_all.sh poc                     # W1 × 4정책 × 1회
sudo -E ./run_all.sh main                    # W1 × 4정책 × 5회
sudo -E ./run_all.sh ksweep                  # Split Batch 조각 수 K = 1, 4, 8, 16
```

`EXPSTAT=1`이면 측정 시작·끝과 cycle마다 스냅샷을 저장하고, 끝나면 `summary.json`을 만든다. `verdict`가 `valid`가 아니면 그 실행은 버린다.

스냅샷을 직접 받을 때:

```bash
sudo nvme admin-passthru /dev/nvme1n1 --opcode=0xC2 --data-len=4096 --read --raw-binary > snap.bin
python3 tools/parse_expstat.py --show snap.bin
python3 tools/parse_expstat.py --bin start.bin end.bin
```

### 카운터의 뜻

이름은 UART 줄과 스냅샷 해석 결과에서 같다.

| 이름 | 뜻 |
| --- | --- |
| `host_wr_B`, `host_wr_cmd` | 호스트 쓰기 명령이 요청한 바이트, 명령 수 |
| `gc_copy_B` | GC가 옮기기로 한 유효 slice의 바이트. 복사 요청을 낸 시점에 센다 |
| `gc_scheduled` | 복사·erase 요청을 모두 낸 victim 블록 수 |
| `erase_issued` | NAND 드라이버에 넘긴 erase 요청 수. `erase_cnt`(완료 기준)는 이 빌드에서 세지 않는다 |
| `prog_host_B`, `prog_gc_B`, `prog_meta_B` | 원인별 NAND program 바이트. 합을 `host_wr_B`로 나눈 값이 장치 WAF |
| `dsm_cmd`, `dsm_range`, `dsm_req_B` | 받은 DSM 명령 수, range 수, 요청 바이트 |
| `dsm_inval_B` | 유효하던 slice를 새로 무효화한 바이트 |
| `dsm_already_free_B` | 이미 매핑이 없던 slice |
| `dsm_ignored_B` | 적용하지 않은 바이트. slice 일부만 걸친 LBA, dirty buffer slice, GC 진행 중이라 건너뛴 명령 |
| `dsm_busy_B` | `dsm_ignored_B` 중 dirty buffer 때문에 건너뛴 양 (`dsm_busy_slices` × 16KB) |
| `dsm_gc_busy_cmds` | GC 복사가 진행 중이라 통째로 적용하지 않은 명령 수 |
| `dsm_errors` | 오류로 완료한 명령 등 |
| `dsm_ticks`, 분포 | 명령 처리 시간 합계와 명령당 분포(2배 간격 구간) |

정상 완료된 명령에 대해서는 `dsm_req_B = dsm_inval_B + dsm_already_free_B + dsm_ignored_B`가 성립한다.

## 6. 알고 써야 할 점

- **schema=3이 아닌 펌웨어에는 스냅샷 명령(0xC2)을 보내지 않는다.** 이전 버전과 원본 펌웨어는 모르는 admin 명령을 받으면 멈춘다. `quickstart.sh`와 `fw_verify.sh`는 이 확인을 먼저 묻는다.
- **원본 펌웨어에는 discard를 보내지 않는다.** `nvme dsm` 같은 passthrough 명령은 커널을 거치지 않고 보드에 도달한다. `blkdiscard`와 스크립트들은 장치가 지원을 표시하지 않으면 보내지 않는다.
- **GC가 진행 중일 때 온 DSM 명령은 적용되지 않는다.** GC가 활발한 구간에서 discard 효과가 줄어 보일 수 있다. 정책 비교 때 `dsm_gc_busy_cmds`와 `dsm_ignored_B`를 함께 본다.
- **보드를 재부팅하면 데이터가 모두 지워진다.** 매핑이 DRAM에만 있고 부팅 때 전체 erase를 한다. 반복 실행의 초기 상태를 맞추는 데는 유리하다.
- **마지막에 쓴 2MB는 discard되지 않을 수 있다.** data buffer(128 엔트리)에 dirty로 남은 slice는 건너뛴다.
- **4KB 임의 쓰기는 WAF가 부풀려진다.** 16KB slice 단위로 program하기 때문이다. 본 실험의 주 지표는 `gc_copy_B`다.
- **discard 뒤 읽기 값은 정해져 있지 않다**(DLFEAT 미설정).
- **펌웨어 주석은 ASCII 영어로 둔다.** 한글 주석이 편집기에서 깨진 적이 있다(`exp_stat.h`).
- **스냅샷 형식을 바꿀 때**는 `exp_stat_t`나 `DSM_STATS` 끝에만 필드를 추가하고 `parse_expstat.py`의 `EXP_FIELDS`, `DSM_FIELDS`를 같이 고친다. `make test`가 순서가 맞는지 확인한다.
