#!/usr/bin/env python3
"""GIT_SEQUENCE_EDITOR: after the pick of each listed commit, amend its message.

Usage:  GIT_SEQUENCE_EDITOR=/root/terratec/upstream/msg/seqedit.py \
        git rebase -i <base>
"""
import sys

MAP = {
    "ASoC: ice1712: fix PHASE 88 chip select expander address":
        "0001-chipselect.txt",
    "ASoC: ice1712: initialise the second PHASE 88 expander register":
        "0004-second-register.txt",
    "ASoC: ice1712: add the PHASE 88 Line/Mic input switch":
        "0005-linemic-alt.txt",
    "ASoC: ice1712: add the PHASE 88 Line/Mic input switches":
        "0005-linemic-four.txt",
    "ASoC: ice1712: claim the second MIDI port of the PHASE 88":
        "0006-midi2.txt",
}
HERE = "/root/terratec/upstream/msg/"

path = sys.argv[1]
out, hit = [], []
for line in open(path):
    out.append(line)
    if line.startswith("pick "):
        subject = line.split(" ", 2)[2].rstrip("\n") if len(line.split(" ", 2)) > 2 else ""
        f = MAP.get(subject)
        if f:
            out.append(f"exec git commit --amend -F {HERE}{f}\n")
            hit.append(subject)
open(path, "w").writelines(out)
sys.stderr.write("seqedit: amended %d commit(s):\n  %s\n" % (len(hit), "\n  ".join(hit)))
