#!/bin/bash
# Does card 0 follow card 1's clock through the sync cable?
#
#   usage: phase88-sync-follow.sh [-d seconds]
#
# ppm comparisons between two identical cards are useless: two PHASE 88s were
# measured only 0.8 ppm apart while free running, which is inside the
# resolution of the DMA timestamp method (~2 ppm over 40 s).  So instead of
# comparing two free crystals, make the master's clock jump by 8 % and look at
# the slave: setting ICE1712_CFG_EXT (bit 0x80 of PCI config 0x60) on a card
# makes it run at 44101 Hz while programmed for 48000, which is 81000 ppm -
# impossible to miss.  If the sync cable carries the master clock, the slave's
# measured capture rate moves with it.
#
# The slave must be on 'IEC958 Input' (the only external clock the Envy24 can
# lock to).  Note two driver behaviours that shape this test:
#   * snd_ice1712_set_pro_rate() returns without writing while a stream is
#     running (ice1712.c:979), so the clock source of the card jackd owns can
#     only be changed with jackd stopped;
#   * 'IEC958 Input' with nothing connected does not stall the chip: the card
#     free ran at 33168 frames/s, so a healthy 48000 on that clock source is
#     itself a sign that a clock really is present.
#
# jackd keeps running: it xruns while the clock is pulled away, and recovers.
set -u

SEC=20
HERE=$(dirname "$(readlink -f "$0")")
CARDS=$(awk '/ICE1712/{print $1}' /proc/asound/cards)
SLAVE=$(echo $CARDS | awk '{print $1}')		# card with SYNC IN  (jackd)
MASTER=$(echo $CARDS | awk '{print $2}')	# card with SYNC OUT
PM=$(basename "$(readlink -f /sys/class/sound/card$MASTER/device)")
CLK='Multi Track Internal Clock'

while [ $# -gt 0 ]; do
	case $1 in
		-d) SEC=$2; shift 2 ;;
		-h) sed -n '1,32p' "$0"; exit 0 ;;
		*) shift ;;
	esac
done

base_cfg() { printf '0x%02x' $(( 0x$(setpci -s $PM 0x60.b) & ~0x80 )); }
master_ext() { setpci -s $PM 0x60.b=$(printf '0x%02x' $(( 0x$(setpci -s $PM 0x60.b) | 0x80 ))); }
restore() {
	echo "--- restoring master clock"
	setpci -s $PM 0x60.b=$(base_cfg)
}
trap restore EXIT

res="$PWD/follow-$$"
run() { # <tag> <label> [action ...]
	local tag=$1
	echo
	echo "=============================================================="
	echo "PHASE $1: $2"
	echo "  master $PM config 0x60 = $(setpci -s $PM 0x60.b)"
	echo "  slave clock source   = $(timeout 5 amixer -c $SLAVE cget name="$CLK" | sed -n 's/.*: values=//p')"
	shift 2
	"$@"
	echo "  master $PM config 0x60 is now $(setpci -s $PM 0x60.b), measuring ..."
	local out
	out=$(timeout $((SEC + 60)) "$HERE/phase88-clock-measure.sh" -d "$SEC" $SLAVE $MASTER 2>&1 |
		grep -vE '^(card [0-9]+: measuring|building)')
	echo "$out"
	# remember the slave rate for the verdict
	local a b
	a=$(echo "$out" | awk -v sl="card $SLAVE:" '$1 " " $2 == sl {print $3}')
	b=$(echo "$out" | awk -v sl="card $MASTER:" '$1 " " $2 == sl {print $3}')
	echo "$tag slave=$a master=$b" >> "$res"
}

: > "$res"
echo "slave  = card $SLAVE (SYNC IN, jackd)"
echo "master = card $MASTER ($PM, SYNC OUT)"
pgrep -x jackd >/dev/null || echo "warning: jackd is not running; the slave has no stream to measure unless the helper takes over"

run A "master internal, slave on IEC958 Input (baseline)"
run B "master EXT: its clock pulled to the 44.1k family" master_ext
run C "master internal again"

echo
echo "=============================================================="
echo "measured rates per phase:"
cat "$res"
python3 - "$res" <<'PYV'
import sys, re
d = {}
for line in open(sys.argv[1]):
    m = re.match(r"(\w) slave=([0-9.]+) master=([0-9.]+)", line)
    if m:
        d[m.group(1)] = (float(m.group(2)), float(m.group(3)))
if "A" not in d or "B" not in d:
    print("not enough data"); sys.exit()
a_s, a_m = d["A"]; b_s, b_m = d["B"]
print(f"master moved {(b_m-a_m)/a_m*1e6:+.0f} ppm (phase A -> B), slave moved {(b_s-a_s)/a_s*1e6:+.0f} ppm")
if b_s < a_s * 0.95:
    print("=> the slave followed the master: the sync cable carries a clock the Envy24 locks to")
elif abs(b_s - a_s) / a_s < 1e-4:
    print("=> the slave ignored the master: the sync cable does not reach the slave clock")
    print("   (or the master does not drive its SYNC OUT at all)")
else:
    print("=> inconclusive, read the numbers above")
PYV
