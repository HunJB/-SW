# 계측·Deallocate 펌웨어 적용과 검증

대상: Cosmos+ OpenSSD GreedyFTL (`src`, 기준 커밋 692cea3).

PC에서 한 것은 문법 검사, 처리 로직 시험, 보드 동작을 흉내 낸 모형으로 검증 스크립트를 돌려 본 것까지다. **보드에서 빌드하거나 실행한 적은 없다.** 4절의 검증을 통과해야 측정에 쓸 수 있다.

## 1. 구성

| 위치 | 내용 |
| --- | --- |
| `src/nvme/dsm_deallocate.c`, `.h` | Dataset Management(Deallocate) 처리. 팀 구현의 로직을 기준으로 정리 |
| `src/exp_stat.c`, `.h` | 카운터, UART 출력, 호스트로 보내는 스냅샷 |
| `src`의 기존 파일 8개 | 호출 한두 줄씩 추가. 바꾼 줄에는 `/* EXP */` 표시 |
| `tests/host/` | PC에서 돌리는 로직 시험 (`make test`) |
| `tools/fw_verify.sh` | 보드 검증 T0~T5 |
| `tools/parse_expstat.py` | 스냅샷 두 개의 차이, WAF, DSM 분포 계산 |
| `tools/split_trim.sh` | Split Batch용 fstrim 분할 |
| `ssd_discard_experiment/` | 4가지 방식 측정 실행기(W1~W3)와 분석 스크립트. 자체 README 참고 |
| `tools/discard_check.sh` | discard 뒤 쓰기 성능이 회복되는지 확인(장치 전체를 채우므로 오래 걸림) |

DSM 통계는 `exp_stat` 한 곳에만 둔다. `dsm_deallocate.c`는 자체 통계 구조체 없이 `exp_on_dsm_*()`만 호출한다.

## 2. 팀이 올린 구현에서 바뀐 점

| 항목 | 원래 | 지금 | 이유 |
| --- | --- | --- | --- |
| CDW10/11 해석 | `IO_DATASET_MANAGEMENT_COMMAND_DW10`, `.dword` | 비트 연산으로 NR, AD 추출 | 저장소의 타입 이름은 `_IO_...`이고 `.dword` 멤버가 없어 컴파일되지 않음 |
| buffer 해시 테이블 | `dataBufHashTable.dataBufHash[...]` | `dataBufHashTablePtr->dataBufHash[...]` | 헤더 선언과 달리 실제 변수는 `dataBufHashTablePtr`(포인터). 헤더 이름으로는 링크되지 않음 |
| include 경로 | `"ftl_config.h"` 등 | `"../ftl_config.h"` 등 | 파일이 `src/nvme/`에 있음 |
| range 목록 수신 | auto DMA로 static 배열에 | direct DMA로 `ADMIN_CMD_DRAM_DATA_BUFFER`(0x200000)에, 길이 지정 | static 배열은 캐시가 켜진 영역에 놓일 수 있음. auto DMA는 4KB 단위 전송이라 길이를 지정할 수 없음 |
| 용량 밖 range | slice마다 검사하며 끝까지 순회 | range 전체를 무시 | 잘못된 길이가 오면 수십억 번 순회할 수 있음 |
| `InvalidateOldVsa()` 결과 | 호출하면 무효화된 것으로 계산 | 호출 뒤 매핑이 실제로 풀렸는지 확인 | 이 함수는 두 매핑 표가 어긋나면 아무것도 하지 않고 돌아옴 |
| 통계 | `DSM_STATS` | `exp_stat`로 통합, 명령당 처리 시간·요청 크기 분포 추가 | 같은 값을 두 곳에서 세지 않기 위해 |
| DSM 지원 표시 | 변경 없음 | `nvme_identify.c`에서 1로 | 이 표시가 없으면 리눅스가 discard를 보내지 않음 |
| GC 진행 여부 stub | `DsmGcInFlight()` | 삭제 | 이 FTL의 GC는 쓰기 경로 안에서 끝까지 실행되어, 이 핸들러가 도는 동안에는 진행 중일 수 없음 |

그대로 둔 것: 완전히 덮인 slice만 무효화, data buffer에 남은 slice 건너뛰기, AD=0이면 변경 없이 완료, FLUSH와 같은 완료 경로.

auto DMA 방식은 지우지 않고 컴파일 옵션으로 남겼다. direct DMA가 보드에서 동작하지 않으면 `dsm_deallocate.h`의 `DSM_PAYLOAD_USE_AUTO_DMA`를 1로 바꿔 다시 빌드해 본다.

## 3. 적용과 빌드

1. 지금 보드에서 쓰는 bitstream과 ELF, 원본 `src` 폴더를 따로 복사해 둔다.
2. `exp-stat` 브랜치의 `src` 폴더로 SDK 프로젝트의 `src`를 교체한다. 새 파일은 `exp_stat.c/.h`, `nvme/dsm_deallocate.c/.h` 네 개다.
3. SDK에서 프로젝트를 새로 고침(F5)하고 빌드한다.

빌드 전에 PC(리눅스)에서 먼저 확인할 수 있다.

```bash
cd tests/host
make test      # Deallocate 범위 계산과 카운터 시험, 스냅샷 필드 순서 확인
make syntax    # 수정한 펌웨어 파일 9개 문법 검사
```

## 4. 보드 검증

보드를 재부팅한 직후에 실행한다. 장치 앞쪽 약 1.6GiB를 덮어쓴다.

```bash
sudo nvme list                      # OpenSSD의 장치 이름과 시리얼 확인 (부팅마다 이름이 바뀔 수 있음)
cd tools
sudo DEV=/dev/nvme1n1 EXPECTED_SERIAL=<시리얼> ./fw_verify.sh
```

| 단계 | 확인하는 것 | 통과 기준 |
| --- | --- | --- |
| T0 | 시리얼, 마운트 여부, DSM 지원 표시, 스냅샷 명령 | ONCS에 DSM 비트, `DISC-MAX` ≠ 0, 스냅샷 해석 성공 |
| T1 | 쓰기 카운터 | 256MiB 쓰기 → `host_wr_B` = 268435456 |
| T2 | 기본 동작 | 64MiB discard → `dsm_inval_B` = 64MiB. 재요청 시 0, `dsm_already_free_B` = 64MiB. 방금 쓴 1MiB는 `dsm_busy_B`로 잡힘 |
| T3 | slice 경계 | 한 LBA 어긋난 1MiB → 63 slice만 무효화, 16KB 무시. 양쪽 slice 내용 그대로 |
| T4 | 데이터 보존 | discard하지 않은 범위 내용 유지, discard한 범위에 다시 쓴 내용 일치 |
| T5 | 동시 실행 | fio 쓰기·CRC 검증 중 다른 범위에 쓰기·discard 반복. 검증 오류 0, `dsm_err` 0 |

한 단계라도 실패하면 스크립트가 멈춘다. T2의 첫 discard가 가장 위험하다. 여기서 명령이 돌아오지 않으면 보드가 멈춘 것이므로 UART의 마지막 출력을 기록하고, `DSM_PAYLOAD_USE_AUTO_DMA=1`로 다시 빌드해 보거나 원본 펌웨어로 되돌린다.

T0~T5를 통과한 뒤, GC가 실제로 줄어드는지는 `discard_check.sh`로 본다(장치 전체를 채우므로 오래 걸린다).

## 5. 측정

측정은 `ssd_discard_experiment/scripts`에서 한다. 자세한 사용법은 그 폴더의 README에 있다.

```bash
cd ssd_discard_experiment/scripts
export EXPECTED_SERIAL=<시리얼> MNT=/mnt/ssd-test EXPSTAT=1
sudo -E ./run_experiment.sh w1 batch 5 1     # 한 번 실행
sudo -E ./run_all.sh main                    # W1 × 4정책 × 5회
sudo -E ./run_all.sh ksweep                  # Split Batch 조각 수 K = 1, 4, 8, 16
```

`EXPSTAT=1`이면 측정 시작·끝과 cycle마다 스냅샷을 저장하고, 끝나면 `summary.json`을 만든다. `verdict`가 `valid`가 아니면 그 실행은 버린다(No Discard인데 discard가 도달했거나, 다른 방식인데 한 번도 도달하지 않았거나, 중간에 보드가 재부팅된 경우).

스냅샷을 직접 받을 때:

```bash
sudo nvme admin-passthru /dev/nvme1n1 --opcode=0xC2 --data-len=4096 --read --raw-binary > snap.bin
python3 parse_expstat.py --show snap.bin
python3 parse_expstat.py --bin start.bin end.bin
```

### 카운터의 뜻

| 이름 | 뜻 |
| --- | --- |
| `host_wr_B` | 호스트 쓰기 명령이 요청한 바이트 |
| `gc_copy_B` | GC가 옮기기로 한 유효 slice의 바이트. 복사 요청을 낸 시점에 센다 |
| `gc_cnt`, `erase_cnt` | 회수한 victim 블록 수, GC가 요청한 erase 수(부팅 때의 전체 erase는 제외) |
| `prog_host_B`, `prog_gc_B` | 원인별 NAND program 바이트. 합을 `host_wr_B`로 나눈 값이 장치 WAF |
| `dsm_cmd`, `dsm_range`, `dsm_req_B` | 받은 DSM 명령 수, range 수, 요청 바이트 |
| `dsm_inval_B` | 유효하던 slice를 새로 무효화한 바이트 |
| `dsm_already_free_B` | 이미 매핑이 없던 slice |
| `dsm_busy_B` | data buffer에 남아 있어 건너뛴 slice |
| `dsm_ignored_B` | slice 일부만 걸친 LBA, 용량 밖 range |
| `dsm_ticks`, 분포 | 명령 처리 시간 합계와 명령당 분포(2배 간격 구간) |
| `dsm_err` | payload 주소가 맞지 않아 처리하지 못한 명령 |

`dsm_req_B = dsm_inval_B + dsm_already_free_B + dsm_busy_B + dsm_ignored_B`가 항상 성립한다.

## 6. 알고 써야 할 점

- **패치 전 보드에는 스냅샷 명령(0xC2)도 보내지 않는다.** 원본 펌웨어는 모르는 admin 명령에도 멈춘다. `EXPSTAT=1`은 계측 펌웨어에서만 쓴다.
- **패치 전 보드에는 discard를 보내지 않는다.** `nvme dsm` 같은 passthrough 명령은 커널을 거치지 않고 보드에 도달하고, 원본 펌웨어는 모르는 I/O 명령을 받으면 멈춘다. `blkdiscard`와 `fw_verify.sh`는 장치가 지원을 표시하지 않으면 보내지 않는다.
- **보드를 재부팅하면 데이터가 모두 지워진다.** 매핑이 DRAM에만 있고 부팅 때 전체 erase를 한다. 반복 실행의 초기 상태를 맞추는 데는 유리하다.
- **마지막에 쓴 2MB는 discard되지 않는다.** data buffer(128 엔트리)에 남은 slice는 건너뛴다. 파일을 지우기 직전에 쓴 데이터가 여기에 해당하며 `dsm_busy_B`로 양을 확인할 수 있다.
- **4KB 임의 쓰기는 WAF가 부풀려진다.** 16KB slice 단위로 program하기 때문이다. 본 실험의 주 지표는 `gc_copy_B`다.
- **discard 뒤 읽기 값은 정해져 있지 않다**(DLFEAT 미설정).
- **대기 중인 NAND 요청과의 겹침은 코드로 막지 않았다.** T5가 이 경우를 시험하지만, 측정 중 fio 검증 오류나 보드 멈춤이 생기면 이 부분을 먼저 의심한다.
- **58GB는 반복 실험에 크다.** `ftl_config.h`의 `USER_BLOCKS_PER_LUN`을 2048에서 512로 줄이면 약 14GB가 되고 OP 비율(10%)은 유지된다. 바꿨다면 manifest에 적는다.
- **스냅샷 형식을 바꿀 때**는 `exp_stat_t` 끝에만 필드를 추가하고 `parse_expstat.py`의 필드 목록을 같이 고친다. `make test`가 둘의 순서가 맞는지 확인한다.
