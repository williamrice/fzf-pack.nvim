"""Exercise real Neovim/fzf in a PTY, using files rather than RPC sockets."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parent.parent
assert os.environ.get("FZF_LUA_PATH"), "Set FZF_LUA_PATH to an existing fzf-lua checkout"

with tempfile.TemporaryDirectory(prefix="fzf-pack-ui-", dir="/tmp") as tmp:
    env = dict(os.environ, TERM="xterm-256color", FZF_PACK_TEST_ROOT=str(root), FZF_PACK_TEST_TMP=tmp)
    env["NVIM_LOG_FILE"] = f"{tmp}/nvim.log"
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
    for name in ("GIT_CONFIG", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS",
                 "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(name, None)
    for name in ("CONFIG", "DATA", "STATE", "CACHE"):
        env[f"XDG_{name}_HOME"] = f"{tmp}/{name.lower()}"
    Path(env["XDG_CONFIG_HOME"] + "/nvim").mkdir(parents=True)
    master, slave = pty.openpty()
    os.set_blocking(master, False)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 48, 160, 0, 0))
    proc = subprocess.Popen(["nvim", "-u", str(root / "tests/ui_init.lua"), "-i", "NONE"],
                            stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    transcript = bytearray()
    state_path = Path(tmp) / "ui-state.json"

    def drain():
        for _ in range(100):
            if not select.select([master], [], [], 0)[0]:
                break
            try:
                data = os.read(master, 65536)
                if not data:
                    break
                transcript.extend(data)
            except OSError:
                break

    def send(keys):
        drain()
        os.write(master, keys)

    def state():
        drain()
        if not state_path.exists():
            return {}
        return json.loads(state_path.read_text())

    def capture(name):
        artifacts = os.environ.get("FZF_PACK_UI_ARTIFACTS")
        if artifacts:
            destination = Path(artifacts)
            destination.mkdir(parents=True, exist_ok=True)
            destination.joinpath(name + ".txt").write_text("\n".join(state().get("screen", [])))
            destination.joinpath(name + ".ansi").write_bytes(transcript)

    def wait(predicate):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            current = state()
            if predicate(current):
                return current
            time.sleep(0.05)
        capture("failure")
        raise AssertionError("UI timed out\n" + transcript[-5000:].decode(errors="replace"))

    terminal = lambda s: s.get("buftype") == "terminal"
    closed = lambda s: s.get("ready") and s.get("buftype") != "terminal" and not s.get("confirmed")
    native = lambda s: s.get("filetype") == "nvim-pack"
    try:
        print("Starting Neovim PTY", flush=True)
        wait(lambda s: s.get("ready"))
        send(b":Pack\r")
        local = wait(lambda s: terminal(s) and "cached" in "\n".join(s.get("screen", [])))
        assert "alpha" in "\n".join(local["screen"])
        capture("local-picker")
        send(b"\x1b")
        assert wait(closed)["unchanged"]
        send(b":PackUpdate\r")
        updated = wait(lambda s: terminal(s) and "UI incoming body" in "\n".join(s.get("screen", [])))
        update_screen = "\n".join(updated["screen"])
        capture("update-picker")
        assert all(name in update_screen for name in ("alpha", "beta", "pinned", "UI incoming subject")), update_screen
        send(b"\t\t\r")
        reviewed = wait(native)
        text = "\n".join(reviewed["lines"])
        assert "## alpha" in text and "## beta" in text and "## pinned" not in text, text
        assert reviewed["unchanged"]
        send(b":quit\r")
        assert wait(closed)["unchanged"]
        send(b":PackUpdate\r")
        wait(terminal)
        wait(lambda s: terminal(s) and "UI incoming body" in "\n".join(s.get("screen", [])))
        send(b"alpha\x01")
        reviewed = wait(native)
        text = "\n".join(reviewed["lines"])
        assert "## alpha" in text and "## beta" in text, text
        send(b":quit\r")
        assert wait(closed)["unchanged"]
        send(b":PackUpdate\r")
        wait(terminal)
        send(b"\x1b")
        final = wait(closed)
        assert final["unchanged"]
        for name in ("alpha", "beta", "pinned"):
            path = env["XDG_DATA_HOME"] + "/nvim/site/pack/core/opt/" + name
            head = subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()
            assert head == final["old"]
        artifact = Path(tempfile.gettempdir()) / "fzf-pack-picker-screen.txt"
        artifact.write_text(update_screen)
        capture("success")
        print(f"PASS: actual picker rendering, bodies, Tab multi-selection, filtered review-all, cancellation; screen: {artifact}")
    except Exception:
        capture("failure")
        raise
    finally:
        if proc.poll() is None:
            try:
                send(b"\x1b:qa!\r")
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
                proc.wait()
        os.close(master)
