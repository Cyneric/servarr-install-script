"""Read-only/cancel tests against the actual entrypoint in a systemd test host."""
import errno
import os
import pty
import select
import subprocess
import time
from pathlib import Path

script = Path(__file__).resolve().parents[1] / "servarr-install-script.sh"
no_tty = subprocess.run(["bash", str(script)], stdin=subprocess.DEVNULL, capture_output=True, text=True)
assert no_tty.returncode != 0 and "interactive terminal is required" in no_tty.stderr, no_tty

for piped in (False, True):
    pid, fd = pty.fork()
    if pid == 0:
        if piped:
            os.execlp("bash", "bash", "-c", 'cat "$1" | bash', "bash", str(script))
        os.execlp("bash", "bash", str(script))
    transcript = b""
    selected_mode = False
    canceled = False
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.2)
            if readable:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                transcript += chunk
                if b"Deployment mode:" in transcript and not selected_mode:
                    os.write(fd, b"2\n")
                    selected_mode = True
                if b"Applications: numbers" in transcript and not canceled:
                    os.write(fd, b"q\n")
                    canceled = True
        else:
            os.kill(pid, 9)
            raise AssertionError("Interactive installer hung: " + repr(transcript))
        _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 0, transcript
        assert canceled and b"bad array subscript" not in transcript, transcript
        print("PASS: terminal cancellation", "piped" if piped else "downloaded")
    finally:
        os.close(fd)
