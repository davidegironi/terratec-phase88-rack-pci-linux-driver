# Tools

Run them from anywhere; scripts resolve the checkout from their own path. Root,
because most touch `/proc/asound`, module loading or `/etc`.

Two rules the whole folder obeys, learned the hard way on this box:

* **ALSA calls need a `timeout`** - a blocked `snd_pcm_open()` becomes an
  unkillable D-state task, and an oops inside one holds the sound-core
  `register_mutex`, which means no module unload until you reboot.  Never
  `rmmod -f` here.
* **This card only accepts `S32_LE`.** `S16_LE` fails with `Sample format non
  available`, and peak meters must ignore the first ~0.6 s because register
  writes make a click.

Tools marked **(ALSA)** open the PCM directly and therefore need **JACK
stopped** (QJackCtl "Stop").  `phase88-loopback.sh` and the MIDI scripts say so
explicitly instead of looking broken.

## Everyday setup

| tool | what it does |
|---|---|
| `phase88-mixer.sh [card]` | unmute + unity gains + 0 dB codecs + front input on, for **every** ICE1712 card, then applies the word-clock roles. Called by `phase88-audio.service` at boot. |
| `phase88-sync-setup.sh [--show\|--off\|master slave]` | clock master/slave via 'Multi Track Internal Clock'. Refuses while a stream runs, because `snd_ice1712_set_pro_rate()` (ice1712.c:979) silently drops the write. Reads `/etc/default/phase88`. |
| `phase88-install-policy.sh [snd-ice1712.ko]` | install `install/etc/*` (and optionally the module, vermagic-checked) on a fresh box. |
| `phase88-package.sh [output.zip]` | create a portable ZIP with all `scripts/`, `install/`, and `module-kit/` files, the v2 patch series, and a package-specific installation explanation. Uses Python 3's standard library; default output is `phase88-install-kit.zip` in the repository root. |
| `phase88-install-jackservice.sh` | install and enable a per-user systemd service that starts JACK at login; chooses `phase88x2` for two cards or `hw:Phase88` for one. Run with `sudo`; service runs as the logged-in desktop user. |
| `phase88-install-jackpulse.sh [desktop-user]` | install JACK plus PulseAudio JACK sink/source modules and user services; refuses root and PipeWire-Pulse setups. Run from the desktop user with `sudo`, or as root with the desktop username. |
| `phase88-verify.sh [card]` | the full check: probe, PCM list, controls, playback at 44.1/48/96 kHz, capture, no oops. Prints `### RESULT: all checks passed`. Pass the card number bare (`phase88-verify.sh 1`, not `-c 1`). Log in `../logs/`. **(ALSA)** |
| `phase88-cycle.sh` | `rmmod` + `modprobe` + `phase88-verify.sh`, with a dmesg watermark so old errors from the distro module do not fail the run. |

## Build and install

For JACK auto-start at desktop login, run `sudo scripts/phase88-install-jackservice.sh`.
It installs a user unit and helper under the target user's home. It starts JACK
immediately if that user is already logged in; otherwise it starts at their next
login. Do not also configure QJackCtl to auto-start a second JACK server.

For JACK plus PulseAudio through the PHASE 88, run
`sudo scripts/phase88-install-jackpulse.sh` from the target desktop user's
account. From a root shell, pass the non-root desktop username explicitly:
`sudo scripts/phase88-install-jackpulse.sh USER`. It installs `jackd2`,
PulseAudio, and `pulseaudio-module-jack`, then enables per-user JACK and bridge
services. The bridge creates the stereo PulseAudio sink `phase88_jack_out` and
source `phase88_jack_in`, sets them as defaults, and connects them to JACK after
both servers are available. It intentionally refuses root and PipeWire-Pulse;
use a regular desktop account. If JACK was previously enabled for root, disable
that root unit first; also disable QJackCtl JACK autostart to avoid a competing
server. Check with `systemctl --user status phase88-jack.service phase88-pulse-jack.service`, `pactl list short sinks`, and `pactl list short sources`. If PulseAudio is restarted later, reload its bridge modules with `systemctl --user restart phase88-pulse-jack.service`.

| tool | what it does |
|---|---|
| `phase88-install-module.sh [--kver=V] [--reload] [--dry-run] [--check]` | build `../module-kit/` (8 files, ~10 s) against `/lib/modules/<V>/build` or `/usr/src/linux-headers-<V>`, back up the old module, install to `/lib/modules/<V>/updates/`, `depmod -a <V>`, then confirm `modprobe --show-depends` picks it. `--reload` also frees `/dev/snd` (stops user pipewire/wireplumber, refuses if a PCM stream is RUNNING), reloads and re-runs the mixer script. `--check` reports installed md5/vermagic, whether it is loaded and what modprobe picks. Takes ~2.5 min because `depmod` is slow here. |
| `/etc/kernel/postinst.d/phase88-oot` (from `install/etc/kernel/`) | runs that script for every kernel `apt` installs, logs to `/var/log/phase88-kernel-hook.log`, always exits 0 so it can never break a kernel install. |

## Levels and inputs

| tool | what it does |
|---|---|
| `phase88-jack-meter.sh [--selftest]` | live peaks of the capture ports **through JACK**; `--selftest` sends a sine to `system:playback_1` and expects it back on the monitor pair (11/12) at about -10 dBFS. Use this while JACK runs. |
| `phase88-jack-io.c` | connect/record through JACK from the shell (needs `jack_dev.h`: `apt install jackd1` dev bits; build `gcc -O2 -o phase88-jack-io phase88-jack-io.c -ljack`). |
| `phase88-loopback.sh` | pure-ALSA sanity check: tone out, look for it in the Envy24 monitor mix, no cable needed. Refuses politely when the card is busy. **(ALSA)** |
| `phase88-linemic-probe.sh` | per-channel dBFS with each `Line/Mic` switch off then on - this is what measured the +28..+33 dB on channels 7/8. **(ALSA)** |
| `phase88-mic-talk-test.sh` | off/on/off while somebody talks into the front mic; reports peak+rms of ch7/ch8 and whether it looks like a mux or a preamp. **(ALSA)** |

## Clock and two-card sync

| tool | what it does |
|---|---|
| `phase88-clock-measure.sh -d SEC [-c 0 -c 1]` | measures each card's real DMA rate in ppm from `(hw_ptr, tstamp)` pairs in `/proc/asound/cardN/pcm0c/sub0/status`, fits with `phase88-clock-report.py`, builds `phase88-pcm-run` if missing. Resolution is one period, so read anything under ~5 ppm as "same clock, unresolved". |
| `phase88-pcm-run.c` | the capture helper that turns DMA timestamps on (ALSA leaves them off for `arecord`, which is why `status` prints `tstamp : 0.000000000`). Build: `gcc -O2 -o phase88-pcm-run phase88-pcm-run.c -L/usr/lib/x86_64-linux-gnu -l:libasound.so.2` (no alsa headers or pkg-config on this box). |
| `phase88-sync-follow.sh` | **the decisive sync test**: perturb only the master by 8 % (PCI config `EXT` bit) and see whether the slave moves with it. That proved the cable carries the clock (-81292 ppm master, -81295 ppm slave). Two cards, **(ALSA)**. |
| `phase88-sync-probe.sh` | phases both-internal / slave-on-EXT-bit / slave-on-IEC958, measured with the clock tool. Two cards, **(ALSA)**. |

## MIDI

| tool | what it does |
|---|---|
| `phase88-midi-racks.sh [--list\|--probe C\|--identify C\|--yes]` | walk the four sockets (rack 1/2 x front/rear) with one loopback cable; `--identify` plays 440 Hz so you learn which card is which rack. |
| `phase88-midi-test.sh [out] [in] [--watch [port] [sec]]` | one loopback or cross-card test; `PORT BUSY` (exit 3) when jackd/Reaper holds the rawmidi device, which is not a hardware failure. |

## RFC / bring-up only (need the RFC module)

`phase88-sync-test.sh` and `phase88-expander-sweep.py` use the debug controls
`Phase88 Debug Expander Page 1` / `Page 3` / `Phase88 Debug Codec Init`, which
exist only in the separate RFC debug build (`d2db56036`, deliberately kept out
of the submission series). The installable `module-kit` no longer includes
these writable controls; a previously loaded diagnostic module retains them
until a safe reload or reboot. With a normal build these scripts skip the
expander-only checks.

## One-shot boot verification

`phase88-postboot.sh` is an optional diagnostic, not part of normal boot. The
installed `phase88-postboot.service` is intentionally disabled and masked; the
script no longer creates a log directory or writes log files if run manually.
