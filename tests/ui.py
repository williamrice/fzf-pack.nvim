"""Exercise real Neovim/fzf in a PTY, using files rather than RPC sockets."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parent.parent
assert os.environ.get("FZF_LUA_PATH"), "Set FZF_LUA_PATH to an existing fzf-lua checkout"

class FixtureDirectory(tempfile.TemporaryDirectory):
    def cleanup(self):
        try:
            super().cleanup()
        except OSError:
            remaining = list(Path(self.name).rglob("*"))
            print("Fixture cleanup failed; remaining paths:", remaining, flush=True)
            raise


with FixtureDirectory(prefix="fzf-pack-ui-", dir="/tmp") as tmp:
    env = dict(os.environ, TERM="xterm-256color", FZF_PACK_TEST_ROOT=str(root), FZF_PACK_TEST_TMP=tmp)
    # The invoking agent/CI shell may disable colors globally. This fixture
    # explicitly tests rendered colors in its isolated terminal.
    env.pop("NO_COLOR", None)
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
    query_buffer = bytearray()
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
                # Neovim waits for a primary device-attributes (DA1) reply
                # when stopping its TUI. Act as a VT100-compatible terminal,
                # including when a request is split across PTY reads.
                query_buffer.extend(data)
                consumed = 0
                for query in re.finditer(rb"\x1b\[(?:0)?c", query_buffer):
                    os.write(master, b"\x1b[?1;2c")
                    consumed = query.end()
                del query_buffer[:consumed]
                del query_buffer[:-3]
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
        send(b"beta")
        wait(lambda s: terminal(s) and "Pack> beta" in "\n".join(s.get("screen", []))
             and "beta (active)" in "\n".join(s.get("screen", [])))
        send(b"\x0f")
        opened = wait(lambda s: terminal(s) and s.get("browser_calls") == ["https://github.com/fixture/beta"])
        assert "Pack> beta" in "\n".join(opened["screen"]) and opened["unchanged"]
        send(b"\x15no-such-plugin")
        wait(lambda s: terminal(s) and "0/3" in "\n".join(s.get("screen", [])))
        send(b"\x0f")
        capture("local-picker")
        send(b"\x1b")
        assert wait(closed)["unchanged"]
        send(b":PackUpdate\r")
        updated = wait(lambda s: terminal(s) and "UI incoming body" in "\n".join(s.get("screen", []))
                       and "history truncated at 300 bytes" in "\n".join(s.get("screen", [])))
        update_screen = "\n".join(updated["screen"])
        capture("update-picker")
        assert all(name in update_screen for name in ("alpha", "beta", "pinned", "UI incoming subject",
                                                      "history truncated at 300 bytes", "[BREAKING CHANGE]")), update_screen

        def row_attributes(screen_state, name, status):
            pattern = re.compile(rf"({re.escape(name)})\s+(active|inactive)\s+({re.escape(status)})")
            for row_index, line in enumerate(screen_state["screen"]):
                match = pattern.search(line)
                if match:
                    attributes = screen_state["attributes"][row_index]
                    return attributes[match.start(1)], attributes[match.start(3)]
            raise AssertionError(f"Could not find {name} {status} list row\n" + "\n".join(screen_state["screen"]))

        _, update_attribute = row_attributes(updated, "beta", "update")
        _, current_attribute = row_attributes(updated, "pinned", "current")
        assert update_attribute != current_attribute, updated
        beta_name_attribute, _ = row_attributes(updated, "beta", "update")
        assert update_attribute != beta_name_attribute, updated

        def assert_commit_rendered(screen_state, subject, body, expected_highlight):
            screen = screen_state["screen"]
            attributes = screen_state["attributes"]
            header_position = subject_position = body_position = None
            for row_index, line in enumerate(screen):
                header = re.search(r"(?:^|│)(commit [0-9a-f]+(?:\s+\[BREAKING CHANGE\])?)\s*(?:│|$)", line)
                if header and row_index + 1 < len(screen) and subject in screen[row_index + 1]:
                    header_position = (row_index, header.start(1))
                if subject in line:
                    subject_position = (row_index, line.index(subject))
                if body in line:
                    body_position = (row_index, line.index(body))
            assert header_position and subject_position and body_position, screen
            header_attribute = attributes[header_position[0]][header_position[1]]
            subject_attribute = attributes[subject_position[0]][subject_position[1]]
            body_attribute = attributes[body_position[0]][body_position[1]]
            highlight = screen_state[expected_highlight]
            if expected_highlight == "commit_highlight":
                assert header_attribute != subject_attribute and header_attribute != body_attribute, screen
                assert highlight.get("bold") is True and highlight.get("fg") == 0x2468AC, highlight
            else:
                assert header_attribute == subject_attribute and header_attribute != body_attribute, screen
                assert highlight.get("bold") is True and highlight.get("fg") == 0xFF0000 \
                    and highlight.get("ctermfg") == 9 and highlight.get("bg") is None, highlight
                warning = "[BREAKING CHANGE]"
                header_line = screen[header_position[0]]
                warning_attribute = attributes[header_position[0]][header_line.index(warning)]
                assert warning_attribute == header_attribute, screen
                for text in ("BREAKING CHANGE: UI API changes", "Migrate callers"):
                    footer_position = next((
                        (row_index, line.index(text))
                        for row_index, line in enumerate(screen)
                        if text in line
                    ), None)
                    assert footer_position, screen
                    footer_attribute = attributes[footer_position[0]][footer_position[1]]
                    assert footer_attribute == header_attribute and footer_attribute != body_attribute, screen

        assert_commit_rendered(updated, "UI incoming subject", "UI incoming body", "breaking_highlight")
        assert_commit_rendered(updated, "UI normal subject", "UI normal body", "commit_highlight")
        assert "BREAKING CHANGE: UI API changes" in update_screen and "Migrate callers" in update_screen, update_screen
        before_tab = "\n".join(updated["screen"])
        send(b"\t")
        marked = wait(lambda s: terminal(s) and "3/3 (1)" in "\n".join(s.get("screen", [])))
        marked_screen = "\n".join(marked["screen"])
        assert marked_screen != before_tab and "alpha" in marked_screen and "update" in marked_screen
        alpha_name_attribute, update_attribute = row_attributes(marked, "alpha", "update")
        assert update_attribute != alpha_name_attribute
        beta_name_attribute, update_attribute = row_attributes(marked, "beta", "update")
        assert update_attribute != beta_name_attribute
        send(b"\x0f")
        opened = wait(lambda s: terminal(s) and s.get("browser_calls") == [
            "https://github.com/fixture/beta", "https://github.com/fixture/beta"])
        assert "3/3 (1)" in "\n".join(opened["screen"]) and opened["unchanged"]
        failure_flag = Path(tmp) / "browser-fails"
        failure_flag.touch()
        send(b"\x0f")
        failed_open = wait(lambda s: terminal(s) and len(s.get("browser_calls", [])) == 3
                           and bool(s.get("browser_notices")))
        assert "fixture has no browser opener" in failed_open["browser_notices"][-1]
        assert "3/3 (1)" in "\n".join(failed_open["screen"]) and failed_open["unchanged"]
        failure_flag.unlink()
        send(b"\t\r")
        reviewed = wait(native)
        text = "\n".join(reviewed["lines"])
        assert "## alpha" in text and "## beta" in text and "## pinned" not in text, text
        assert reviewed["unchanged"]
        send(b":quit\r")
        assert wait(closed)["unchanged"]
        send(b":PackUpdate\r")
        wait(terminal)
        wait(lambda s: terminal(s) and "UI incoming body" in "\n".join(s.get("screen", []))
             and "history truncated at 300 bytes" in "\n".join(s.get("screen", [])))
        send(b"alpha")
        wait(lambda s: terminal(s) and "PackUpdate> alpha" in "\n".join(s.get("screen", []))
             and "1/3" in "\n".join(s.get("screen", []))
             and "UI incoming body" in "\n".join(s.get("screen", [])))
        send(b"\x01")
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
        alpha_path = Path(env["XDG_DATA_HOME"]) / "nvim/site/pack/core/opt/alpha"
        subprocess.run(["git", "-C", str(alpha_path), "reset", "--hard", final["new"]],
                       check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "-C", str(Path(tmp) / "upstream"), "update-ref",
                        "refs/heads/main", final["old"]], check=True, stdout=subprocess.DEVNULL)
        send(b":PackUpdate\r")
        removed = wait(lambda s: terminal(s)
                       and "Removed commits" in "\n".join(s.get("screen", []))
                       and "UI incoming body" in "\n".join(s.get("screen", []))
                       and "[BREAKING CHANGE]" in "\n".join(s.get("screen", [])))
        removed_screen = "\n".join(removed["screen"])
        assert "UI incoming subject" in removed_screen, removed_screen
        assert_commit_rendered(removed, "UI incoming subject", "UI incoming body", "breaking_highlight")
        assert_commit_rendered(removed, "UI normal subject", "UI normal body", "commit_highlight")
        capture("removed-picker")
        send(b"\x1b")
        assert wait(closed)["unchanged"]
        artifact = Path(tempfile.gettempdir()) / "fzf-pack-picker-screen.txt"
        artifact.write_text(update_screen)
        capture("success")
        # Regression: teardown must also work while keys would go to fzf,
        # rather than to Neovim's command line.
        send(b":Pack\r")
        wait(terminal)
    except Exception:
        capture("failure")
        raise
    finally:
        try:
            # The TUI process exiting does not establish that the editor's
            # scheduled screen writer has stopped. Quiesce it before teardown.
            Path(tmp, "stop-observer").touch()
            stopped = Path(tmp, "observer-stopped")
            deadline = time.monotonic() + 5
            while not stopped.exists() and time.monotonic() < deadline:
                drain()
                time.sleep(0.05)
            assert stopped.exists(), "Screen observer did not acknowledge shutdown"
            frozen_state = state_path.read_bytes() if state_path.exists() else None
            deadline = time.monotonic() + 5
            while proc.poll() is None and time.monotonic() < deadline:
                # A blocking wait can leave the editor stuck writing to a full PTY.
                drain()
                time.sleep(0.05)
            if proc.poll() is None:
                capture("shutdown-failure")
                raise AssertionError("Neovim did not exit after observer shutdown\n"
                                     + transcript[-5000:].decode(errors="replace"))
            assert proc.returncode == 0, f"Neovim exited with status {proc.returncode}"
            assert (state_path.read_bytes() if state_path.exists() else None) == frozen_state, (
                "Screen observer wrote after acknowledging shutdown"
            )
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)

print(f"PASS: picker rendering, selection, cancellation, observer shutdown and fixture cleanup; screen: {artifact}")
