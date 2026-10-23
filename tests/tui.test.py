#!/usr/bin/env python3
"""python3 -I tests/tui.test.py — keycue-config without a running shell.

Snapshot mode checks each editor and the saved file; a pseudo-terminal run
checks raw mode, opening the editor (EDITOR=true) and quitting cleanly.
"""

import json
import os
import pty
import re
import select
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TUI = os.path.join(HERE, "..", "bin", "keycue-config")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
failures = 0


def check(name, ok, detail=""):
    global failures
    failures += not ok
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + detail))


def snapshot(config, keys="", size="100x30"):
    out = subprocess.run([sys.executable, "-I", TUI, "--config", config, "--no-ipc", "--snapshot", size, "--keys", keys],
                         capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise SystemExit(out.stderr)
    return ANSI.sub("", out.stdout)


def jsonc(path):
    text = open(path).read()
    text = "\n".join(line for line in text.splitlines() if not line.strip().startswith("//"))
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", text))


tmp = tempfile.mkdtemp(prefix="keycue-tui-")
cfg = os.path.join(tmp, "keycue.jsonc")

screen = snapshot(cfg)
check("missing file shows defaults", "Delay" in screen and "400 ms" in screen and not os.path.exists(cfg))

screen = snapshot(cfg, "j<enter>")
check("flags editor opens", "Pick one or more" in screen)
screen = snapshot(cfg, "jjjjjjj<enter>")
check("list editor opens", "a add" in screen and "Disabled apps" in screen)
screen = snapshot(cfg, "]j<enter>")
check("map editor opens", "Rename bindings" in screen and "a add" in screen)
screen = snapshot(cfg, "<enter>")
check("number prompt opens", "enter save" in screen)

snapshot(cfg, "<right><right>")
check("arrows step and save", jsonc(cfg)["delay"] == 500, open(cfg).read()[:200])
snapshot(cfg, "x")
check("x resets to default", jsonc(cfg)["delay"] == 400)

open(cfg, "w").write('{ "backgroundOpacity": 0.65, "keep": 1 }')
snapshot(cfg, "<end><left>")
data = jsonc(cfg)
check("fraction migrates, unknown keys kept", data["backgroundOpacity"] == 65 and data["keep"] == 1 and data["animationMs"] == 80, str(data))

screen = snapshot(cfg, "<end><enter><ctrl-u>abc<enter>")
check("bad number is refused", "Not a number" in screen and jsonc(cfg)["animationMs"] == 80)

open(cfg, "w").write('{ "delay": 1, oops }')
screen = snapshot(cfg, "<right>")
check("broken file is never overwritten", open(cfg).read() == '{ "delay": 1, oops }' and "errors" in screen)

# Real terminal: raw mode, editor round trip, quit.
open(cfg, "w").write("{}")
pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ, EDITOR="true", VISUAL="", COLUMNS="100", LINES="30")
    os.execve(sys.executable, [sys.executable, "-I", TUI, "--config", cfg, "--no-ipc"], env)
output = b""


def pump(seconds):
    global output
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                output += os.read(fd, 65536)
            except OSError:
                return


pump(1.0)
os.write(fd, b"e")
pump(1.0)
os.write(fd, b"q")
pump(1.0)
_, status = os.waitpid(pid, 0)
text = output.decode(errors="replace")
check("pty: exits cleanly", os.WEXITSTATUS(status) == 0, "status %r" % status)
check("pty: alt screen entered and left", text.count("\x1b[?1049h") >= 2 and text.rstrip().endswith("\x1b[?1049l"))
check("pty: editor reload message", "Reloaded the file" in ANSI.sub("", text))

print("all passed" if failures == 0 else "%d failed" % failures)
sys.exit(1 if failures else 0)
