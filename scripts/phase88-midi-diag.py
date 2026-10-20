#!/usr/bin/env python3
"""Phase88 MIDI port diagnostic - characterise corruption, not just 'works/does not'.

    usage: phase88-midi-diag.py <hw:X,Y> [--reps N] [--card-noise]

Sends a set of patterns through a loopback cable on one port and compares what
comes back, byte by byte:

  sysex   the usual 18 byte frame, 3 times
  asc     0x00..0x7F ascending, twice   (shows which positions/values go missing)
  fiftysix 0x55 repeated 64             (alternating bits: worst case for timing)
  aaaaaa   0xAA repeated 64             (same, opposite phase)
  slow    32 bytes, one every 25 ms     (no queueing: a FIFO overrun cannot hide)
  burst   240 bytes at full speed       (FIFO / interrupt latency)

Reads back the whole stream and reports: bytes sent vs received, position of the
first difference, the XOR distribution (a constant XOR means a stuck line or a
wrong bit order, scattered XOR means noise or marginal timing), and whether the
received data is just the same pattern shifted.

amidi is used for the I/O (one client at a time: stop jackd and Reaper first).
Nothing here touches the driver or the card's registers.
"""
import subprocess
import sys
import time
import os
import collections

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(2)

PORT = sys.argv[1]
REPS = 1
NOISE = "--card-noise" in sys.argv
# --pattern NAME --repeat N : measure one pattern N times and report the error
# rate per run.  A hardware-bit problem gives a stable rate that does not care
# about CPU load; an overrun tracks load and loses whole bytes instead of
# flipping single ones.
PATTERN = None
REPEAT = 0
LOAD = "--load" in sys.argv
# Cross tests: the loopback ties one socket's own transmit to its own receive,
# so on its own it cannot say which side is broken.  With --tx=<other port> the
# bytes are sent by a known-good port and only the port under test receives
# (that is an RX test); with --rx=<other port> the port under test sends and a
# known-good port listens (a TX test).
TX_PORT = None
RX_PORT = None

# ---------------------------------------------------------------- I/O helpers
def holder(port):
    """pid holding a rawmidi device, or '' (rawmidi allows exactly one client)"""
    n = port[3:].split(",")
    dev = f"/dev/snd/midiC{int(n[0])}D{int(n[1]) if len(n) > 1 else 0}"
    if not os.path.exists(dev):
        return None, f"no such rawmidi device: {dev}"
    return subprocess.run(["fuser", dev], capture_output=True,
                          text=True).stdout.strip(), None


def send(data, port=None):
    """Write bytes out of the port. amidi -s needs a file, so use a temp one."""
    port = port or TX_PORT
    path = "/tmp/p88-diag-tx.bin"
    with open(path, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    r = subprocess.run(["amidi", "-p", port, "-s", path],
                       capture_output=True, text=True, timeout=20)
    return r.returncode, r.stderr.strip()


def receive(port=None, secs=2.0):
    """Start a capture on the port; returns (path, Popen)."""
    port = port or RX_PORT
    path = "/tmp/p88-diag-rx.bin"
    if os.path.exists(path):
        os.unlink(path)
    p = subprocess.Popen(
        ["amidi", "-p", port, "-r", path, "-t", str(int(secs + 1))],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.4)                      # let the receiver open the port first
    return path, p


def slurp(path, proc):
    proc.wait(timeout=15)
    if not os.path.exists(path):
        return b""
    with open(path, "rb") as f:
        return f.read()


# ---------------------------------------------------------------- analysis
def xor_profile(sent, got):
    """Compare positionally and describe the differences."""
    n = min(len(sent), len(got))
    diff = [(i, sent[i], got[i]) for i in range(n) if sent[i] != got[i]]
    xors = collections.Counter(s ^ g for _, s, g in diff)
    bits = 0
    for _, s, g in diff:
        bits |= (s ^ g)
    return diff, xors, bits


def bit_histogram(sent, got):
    """how often each bit position came back wrong (0 = LSB = first data bit)"""
    h = [0] * 8
    for i in range(min(len(sent), len(got))):
        x = sent[i] ^ got[i]
        for k in range(8):
            if x >> k & 1:
                h[k] += 1
    return h


def reverse_bits(b):
    return int(f"{b:08b}"[::-1], 2)


def looks_permuted(sent, got):
    """Is the whole received stream the sent stream bit-reversed?"""
    rev = bytes(reverse_bits(x) for x in sent)
    return rev == got


def report(name, sent, got):
    ds = len(sent)
    dg = len(got)
    diff, xors, bits = xor_profile(sent, got)
    verdict = "identical" if dg == ds and not diff else "DIFFERENT"
    print(f"  {name:<9} sent {ds:>3}  got {dg:>3}  differing {len(diff):>3}  -> {verdict}")
    if verdict == "identical":
        return True
    if diff:
        i, s, g = diff[0]
        print(f"            first difference at byte {i}: sent 0x{s:02x} got 0x{g:02x}")
        shown = ", ".join(f"{i:#x}:{s:02x}>{g:02x}" for i, s, g in diff[:12])
        print(f"            {shown}{' ...' if len(diff) > 12 else ''}")
        top = ", ".join(f"0x{x:02x}x{c}" for x, c in xors.most_common(5))
        print(f"            XOR values: {top}")
        print("            errors per bit (0 = LSB, first bit on the wire): "
              + " ".join(str(v) for v in bit_histogram(sent, got)))
    if dg and ds and looks_permuted(sent, got):
        print("            NOTE: received is the sent stream with each byte BIT-REVERSED")
        print("                  - that is swapped data+ / data- or a non-MIDI receiver,")
        print("                  not noise.")
    if dg != ds:
        print(f"            byte count differs by {dg - ds:+d}"
              f" ({'lost' if dg < ds else 'extra bytes: noise or echo'})")
    return False


# ---------------------------------------------------------------- patterns
def pattern_bytes(name, reps):
    if name == "sysex":
        p = b"\xf0\x43\x12\x00phase88\xf7\xb0\x07\x64\x90\x3c\x00"
    elif name == "asc":
        p = bytes(range(0x80))
    elif name == "fiftysix":
        p = b"\x55" * 64
    elif name == "aaaaaa":
        p = b"\xaa" * 64
    elif name == "burst":
        p = bytes(range(0x80)) + bytes(range(0x7F, -1, -1))
    elif name == "sparse":
        # transition-poor bytes: 0x00 (only the start bit falls), 0x7F, 0xFF,
        # 0x01, 0xFE.  Compared against 0x55/0xAA (a transition on every bit)
        # this separates a timing/edge-rate fault - sparse bytes come back
        # clean, dense ones do not - from a plain level problem, which hurts
        # everything equally.
        p = bytes([0x00, 0x7F, 0xFF, 0x01, 0xFE, 0x00, 0xFF, 0x7F])
    elif name == "ff":
        p = b"\xff" * 64
    elif name == "00":
        p = b"\x00" * 64
    elif name == "slow":
        # one byte per write, 30 ms apart: no burst pressure, no FIFO backlog,
        # every byte sits alone on the wire.  If a fault survives this it is
        # purely electrical (or the baud rate is wrong), not a buffering effect.
        p = bytes(range(0x40))
    else:
        raise KeyError(name)
    return p * reps


def one_shot(name):
    """send one pattern once, return (sent, got)"""
    sent = pattern_bytes(name, 1)
    path, proc = receive(secs=2.5 + (0.03 * len(sent) if name == "slow" else 0))
    if name == "slow":
        for b in sent:
            rc, err = send(bytes([b]))
            if rc != 0:
                print(f"  send failed: {err}")
                return None, None
            time.sleep(0.03)
        return sent, slurp(path, proc)
    rc, err = send(sent)
    if rc != 0:
        print(f"  send failed: {err}")
        return None, None
    return sent, slurp(path, proc)


def repeat_mode():
    import math
    print(f"=== {PORT}: pattern '{PATTERN}' x{REPEAT}{' WITH cpu load' if LOAD else ''} ===")
    load = []
    if LOAD:
        for _ in range(os.cpu_count() or 4):
            load.append(subprocess.Popen(["bash", "-c", "while :; do :; done"],
                                         stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL))
        time.sleep(1.0)
    rates, losses = [], []
    bitsh = [0] * 8
    recvd = 0
    try:
        for i in range(REPEAT):
            sent, got = one_shot(PATTERN)
            if sent is None:
                continue
            recvd += len(got)
            diff, _, _ = xor_profile(sent, got)
            rates.append(100.0 * len(diff) / max(1, len(sent)))
            losses.append(len(got) - len(sent))
            for k, v in enumerate(bit_histogram(sent, got)):
                bitsh[k] += v
            print(f"  run {i + 1:>2}: {len(got):>3}/{len(sent)} bytes, "
                  f"{len(diff):>3} wrong ({rates[-1]:5.1f} %), {losses[-1]:+d}")
    finally:
        for p in load:
            p.terminate()
    if not rates:
        print("  nothing measured")
        return
    if not recvd:
        # printing '0.0 % wrong' for a run where nothing arrived reads as
        # 'perfect', which is the opposite of the truth
        print(f"  NO DATA: nothing arrived at {RX_PORT} from {TX_PORT}.  Either there")
        print("  is no cable between those two ports, the wrong socket is in use, or")
        print("  the sending side is dead.  Error rates would be meaningless, so they")
        print("  are not printed.")
        return
    mean = sum(rates) / len(rates)
    sd = math.sqrt(sum((r - mean) ** 2 for r in rates) / len(rates))
    print(f"  mean error rate {mean:.1f} % (sd {sd:.1f}), byte delta range "
          f"{min(losses)}..{max(losses)}")
    print("  errors per bit position (0 = LSB, first bit after the start bit):")
    print("    " + "  ".join(f"b{k}:{v}" for k, v in enumerate(bitsh)))
    lo, hi = sum(bitsh[:3]), sum(bitsh[5:])
    print(f"    low bits {lo}, high bits {hi} - a strong tilt to the HIGH bits means the")
    print("    sampling clock drifts within a byte (baud/clock problem); a flat spread")
    print("    means jitter or a marginal signal, not a wrong baud rate.")
    print(f"  load was {'ON' if LOAD else 'off'}; compare the two runs: load-dependent")
    print("  = interrupt/FIFO problem, load-independent with scattered single-bit")
    print("  errors = electrical (socket, optocoupler, line driver).")


def main():
    if not PORT.startswith("hw:"):
        print("give a port like hw:1,0")
        sys.exit(2)

    global PATTERN, REPEAT, TX_PORT, RX_PORT
    TX_PORT = RX_PORT = PORT            # default: loop back on itself
    args = sys.argv[2:]
    for i, arg in enumerate(args):
        if arg.startswith("--pattern"):
            if "=" in arg:
                PATTERN = arg.split("=", 1)[1]
            elif i + 1 < len(args):
                PATTERN = args[i + 1]
        elif arg == "--repeat" and i + 1 < len(args):
            REPEAT = int(args[i + 1])
        elif arg.startswith("--tx") and "=" in arg:
            TX_PORT = arg.split("=", 1)[1]      # other port sends: RX test
        elif arg.startswith("--rx") and "=" in arg:
            RX_PORT = arg.split("=", 1)[1]      # other port listens: TX test
    for p in (TX_PORT, RX_PORT):
        if not p.startswith("hw:"):
            print(f"give ports like hw:1,0 (got {p})")
            sys.exit(2)
        h, err = holder(p)
        if err:
            print(err)
            sys.exit(2)
        if h:
            print(f"port {p} is held by: {h} - stop jackd/Reaper first")
            sys.exit(3)
    if TX_PORT != RX_PORT:
        if RX_PORT == PORT:
            print(f"RX test: {TX_PORT} sends, {PORT} receives "
                  f"(a clean send is assumed - use a port that passes its own "
                  f"loopback)")
        else:
            print(f"TX test: {PORT} sends, {RX_PORT} receives")

    if PATTERN:
        if not REPEAT:
            REPEAT = 5
        repeat_mode()
        return

    print(f"=== PHASE 88 MIDI port diagnostic {PORT}  {time.strftime('%F %T')} ===")
    ok = 0
    total = 0
    for name in ("sysex", "asc", "fiftysix", "aaaaaa", "burst"):
        sent = pattern_bytes(name, REPS)
        path, proc = receive(secs=2.5)
        rc, err = send(sent)
        if rc != 0:
            print(f"  {name:<9} send failed: {err}")
            continue
        got = slurp(path, proc)
        total += 1
        ok += 1 if report(name, sent, got) else 0
        time.sleep(0.3)

    # slow: one byte every 25 ms, written through amidi's stdin
    # one byte per amidi call, 30 ms apart: nothing ever sits in a queue, so an
    # overrun cannot be the excuse.  ('amidi -p port' with no -s/-r does nothing
    # at all - it complains and exits - so stdin pacing is not an option.)
    sent = bytes(range(0x20, 0x40))
    path, proc = receive(secs=2.0 + 0.04 * len(sent))
    for b in sent:
        with open("/tmp/p88-diag-slow.bin", "wb") as f:
            f.write(bytes([b]))
        subprocess.run(["amidi", "-p", PORT, "-s", "/tmp/p88-diag-slow.bin"],
                       capture_output=True, timeout=10)
        time.sleep(0.03)
    got = slurp(path, proc)
    total += 1
    ok += 1 if report("slow", sent, got) else 0

    print(f"\n  {ok}/{total} patterns came back clean")
    if ok == 0:
        print("  nothing correct at any rate or pattern: look at the XOR line - a")
        print("  constant XOR or a bit-reversal is wiring/logic, scattered differences")
        print("  at every speed are an electrical or opto problem in this socket.")
    elif ok < total:
        print("  the clean patterns tell the limits: 'slow' clean + 'burst' dirty =")
        print("  overrun/interrupt latency; 'slow' dirty = the baud/clock itself.")


if __name__ == "__main__":
    main()
