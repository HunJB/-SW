#!/usr/bin/env python3
"""
보드의 UART 출력을 받으면서 줄마다 받은 시각(epoch ns)을 붙여 파일에 저장한다.

이 시각으로 호스트 PC에서 기록한 이벤트(측정 시작·끝, cycle 끝)와 UART의 EXPSTAT 줄을
맞춘다. 그러려면 UART를 받는 PC와 실험을 돌리는 호스트 PC의 시계가 맞아 있어야 한다
(둘 다 `timedatectl` 에서 "System clock synchronized: yes").

사용법 (UART 케이블이 연결된 PC에서):
  sudo python3 uart_capture.py /dev/ttyUSB1 uart.log
  끝낼 때 Ctrl+C

주의
  - SDK 터미널이나 minicom 등 같은 포트를 연 다른 프로그램을 먼저 닫는다.
    두 프로그램이 같은 포트를 읽으면 줄이 나뉘어 둘 다 일부만 받는다.
  - 받은 내용은 화면에도 그대로 보여 준다.
  - 같은 파일에 이어 쓰므로 실험 하루 동안 한 파일로 받아도 된다.
"""
import os
import subprocess
import sys
import time


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    dev, out = sys.argv[1], sys.argv[2]
    baud = os.environ.get("BAUD", "115200")
    subprocess.run(["stty", "-F", dev, baud, "raw", "-echo", "-echoe", "-echok", "-ixon"], check=True)

    buf = b""
    with open(dev, "rb", buffering=0) as src, open(out, "a", buffering=1) as dst:
        dst.write(f"{time.time_ns()}\t# uart_capture start dev={dev} baud={baud}\n")
        try:
            while True:
                chunk = src.read(256)
                if not chunk:
                    continue
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("utf-8", errors="replace").rstrip("\r")
                    dst.write(f"{time.time_ns()}\t{text}\n")
                    print(text, flush=True)
        except KeyboardInterrupt:
            dst.write(f"{time.time_ns()}\t# uart_capture stop\n")


if __name__ == "__main__":
    main()
