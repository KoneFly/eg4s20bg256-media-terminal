"""按顺序运行一个 TD 脚本，可选用文件锁保证同一时刻只跑一个 TD。

用法：python -I td_serial.py <tcl 文件> <日志文件> [锁文件路径]
不传锁文件时直接运行；传了锁文件但拿不到时会每 30 秒重试，最多等待 60 分钟。
"""
import subprocess
import sys
import time
from pathlib import Path

TD_EXE = "D:/AnLu/bin/td_commands_prompt.exe"


def main():
    tcl, log = sys.argv[1], sys.argv[2]
    if len(sys.argv) <= 3:
        with open(log, "wb") as out:
            return subprocess.call([TD_EXE, tcl], stdout=out, stderr=subprocess.STDOUT)
    import msvcrt
    lock_path = Path(sys.argv[3])
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+b") as fh:
        t0 = time.monotonic()
        while True:
            try:
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError:
                if time.monotonic() - t0 > 3600:
                    print("TD_LOCK_TIMEOUT", flush=True)
                    return 9
                print("TD_WAIT_LOCK", flush=True)
                time.sleep(30)
        print("TD_LOCKED", flush=True)
        with open(log, "wb") as out:
            rc = subprocess.call([TD_EXE, tcl], stdout=out, stderr=subprocess.STDOUT)
        fh.seek(0)
        msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
    return rc


if __name__ == "__main__":
    sys.exit(main())
