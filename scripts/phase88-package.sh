#!/usr/bin/env bash
# Build a portable ZIP containing the PHASE 88 driver kit and installation tools.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
OUTPUT=${1:-"$REPO_ROOT/phase88-install-kit.zip"}

for required in scripts install module-kit analysis/README.md submission/v2; do
  if [[ ! -e "$REPO_ROOT/$required" ]]; then
    printf 'ERROR: required package input is missing: %s\n' "$REPO_ROOT/$required" >&2
    exit 1
  fi
done
command -v python3 >/dev/null || { echo 'ERROR: python3 is required to create the ZIP' >&2; exit 1; }

# Resolve relative output paths against the caller's current directory, then
# create the parent before staging. Refuse to overwrite a directory.
if [[ "$OUTPUT" != /* ]]; then OUTPUT="$PWD/$OUTPUT"; fi
mkdir -p "$(dirname -- "$OUTPUT")"
if [[ -d "$OUTPUT" ]]; then
  printf 'ERROR: output path is a directory: %s\n' "$OUTPUT" >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/phase88-package.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/phase88-install-kit"
mkdir -p "$STAGE"

# Preserve the repository layout: the installers locate sibling directories
# relative to their own paths. Keep the complete scripts directory because
# install and diagnostic helpers call one another.
cp -a "$REPO_ROOT/scripts" "$STAGE/"
cp -a "$REPO_ROOT/install" "$STAGE/"
cp -a "$REPO_ROOT/module-kit" "$STAGE/"
mkdir -p "$STAGE/analysis" "$STAGE/submission"
cp -a "$REPO_ROOT/analysis/README.md" "$STAGE/analysis/README.md"
cp -a "$REPO_ROOT/submission/v2" "$STAGE/submission/"

cat > "$STAGE/PACKAGE-README.md" <<'DOC'
# TerraTec PHASE 88 Linux installation kit

This ZIP is a portable deployment kit for the PHASE 88 (`ICE1712`) Linux
support in this project. It includes the patched out-of-tree driver source
(`module-kit/`), the `phase88-install-*` scripts and their helper/diagnostic
scripts (`scripts/`), system configuration and matching prebuilt modules
(`install/`), the complete installation guide, and the v2 patch series for
reference (`submission/v2/`). `analysis/README.md` is included because the
installed systemd unit points to it for documentation.

## Recommended installation on a new Debian/Ubuntu-like PC

1. Extract the ZIP to a persistent location. For example, extract the archive
   under `/opt`; it creates `/opt/phase88-install-kit/`. **Do not extract into
   `/tmp` or delete this directory after installing:** the Debian kernel-update
   hook calls `scripts/phase88-install-module.sh` and reads `module-kit/` here
   whenever a new kernel is installed.
2. Install build tools and headers for the kernel you are currently running:

   ```sh
   sudo apt install build-essential linux-headers-$(uname -r)
   ```

   If matching headers are unavailable, install the matching kernel headers or
   boot a kernel for which they are available. Secure Boot may require signing
   the locally built module (or another locally approved module-loading setup).
3. Build and install the patched driver for the running kernel:

   ```sh
   cd /opt/phase88-install-kit
   sudo scripts/phase88-install-module.sh
   ```

   This builds `module-kit/` against the running kernel's build tree, installs
   `snd-ice1712.ko` under `/lib/modules/<kernel>/updates/`, and runs `depmod`.
   It does not reload a driver that is already in use.
4. Install the PHASE 88 system policy and Debian kernel-update hook:

   ```sh
   sudo scripts/phase88-install-policy.sh
   ```

   Review `/etc/default/phase88` and set master/slave roles to match the actual
   word-clock wiring. Existing `/etc/default/phase88` is intentionally left
   unchanged. The installer enables `phase88-audio.service` for mixer setup.
5. Reboot, or arrange a safe driver reload while no audio application is using
   the card. Do not force-unload the sound driver. Then stop JACK/PipeWire users
   of the card as appropriate and run `scripts/phase88-verify.sh` to verify it.

Optional desktop audio integration installers are `scripts/phase88-install-jackservice.sh`
(JACK at desktop login) and `scripts/phase88-install-jackpulse.sh` (JACK plus
PulseAudio bridge). Read `install/README.md` and `scripts/README.md` first; the
JACK/PulseAudio installer must be run for the non-root desktop user and refuses
unsupported PipeWire-Pulse setups.

## Prebuilt modules and portability

`install/modules/` contains prebuilt modules only for the kernel versions
identified in their filenames and accompanying `MODINFO-*.txt` records. A
kernel module must match the target kernel's `vermagic`; do not install a
prebuilt module just because its CPU architecture appears compatible. The
recommended build command above uses the new PC's own headers. Building requires
network/package access only if the matching headers or build tools are not
already installed.

The kit contains the eight-source-file out-of-tree module, not a complete Linux
kernel tree. The v2 patch series is included as provenance/reference; it is not
needed to build because the patched source is already in `module-kit/`. The
Debian `/etc/kernel/postinst.d/` hook handles Debian kernel package updates; on
other distributions, run `scripts/phase88-install-module.sh --kver=<version>`
for each kernel or configure that distribution's equivalent update hook.

For details, troubleshooting, one/two-card setup, uninstall steps, and script
requirements, see `install/PHASE88-GUIDE.md`, `install/README.md`,
`module-kit/README.md`, and `scripts/README.md`.
DOC

# Record exactly what went into the archive. The checksum list excludes itself.
(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

python3 - "$STAGE" "$OUTPUT" <<'PY'
import os
import pathlib
import sys
import zipfile

stage = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(stage.rglob("*")):
        if path.is_file():
            archive.write(path, path.relative_to(stage.parent))
PY

printf 'Created %s\n' "$OUTPUT"
printf 'Contents: scripts/, install/, module-kit/, submission/v2/, analysis/README.md, PACKAGE-README.md, SHA256SUMS\n'
