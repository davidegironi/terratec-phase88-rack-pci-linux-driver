# Archive: everything that survives deleting the 25 G kernel tree

Two `git bundle` files hold the entire development history of the driver - 12 KB
each, because they contain only the commits above the baseline, not the kernel's
40 years of history.

| file | branch | contents |
|---|---|---|
| `phase88-commits.bundle` | `phase88-alt-single` | **recommended**: 6 submission commits + the RFC commit (`2e145dfc9`) on top. One `Line/Mic 7/8 Switch`. |
| `phase88-commits-four-switch.bundle` | `phase88` | the same work with four `Line/Mic n/n Switch` controls (253 insertions instead of 224) |

Both need the baseline commit `941c14e58` ("Linux 6.18.55 baseline working"),
which is a plain `linux-6.18.55` release plus a working-tree snapshot; fetch the
tarball and commit it, or use `../kernel/linux-6.18.55.tar.xz` (148 MB) if you
still have it.

## Restore the history

```sh
cd /path/to/a/linux-6.18.55-checkout-at-941c14e58
git fetch /root/terratec/archive/phase88-commits.bundle phase88-alt-single:phase88-alt-single
git bundle verify /root/terratec/archive/phase88-commits.bundle     # says what it requires
```

You do **not** need the history to build or to send the patches:
`../upstream/alt-single-switch/series/` has them as mail, `../upstream/phase88-fix.patch`
as one combined diff, and `../module-kit/` has the ready-to-compile sources.

## What has to be kept, and what does not

| keep | size | why |
|---|---|---|
| everything in this repo **except** `kernel/` | 16 MB | analysis, patches, kit, scripts, `/etc` files, prebuilt modules |
| `kernel/linux-6.18.55.tar.xz` | 148 MB | only if you want to rebuild the *custom* 6.18.55 kernel or its build dir offline - it is also on kernel.org |
| `install/modules/snd-ice1712-*.ko.xz` | 0.6 MB | the binaries this machine runs; enough to restore audio with no compiler at all |

| delete | frees | note |
|---|---|---|
| `kernel/linux-6.18.55/` | 25 GB | build artefacts + source + 281 MB of git objects. See the two options below. |

**Option A - delete it.** The installed module in `/lib/modules/6.18.55/updates/`
keeps working: loading a module never needs the source tree. You lose the ability
to compile for kernel 6.18.55 until you re-unpack the tarball and run
`make modules_prepare`, because `/lib/modules/6.18.55/build` is a symlink into
that tree. Future Debian kernels are unaffected - `linux-headers-*` + the kit
rebuild in 10 s.

```sh
rm -rf /root/terratec/kernel/linux-6.18.55        # keep the .tar.xz next to it
```

**Option B - prune it, keep it buildable (25 GB -> about 1.7 GB: 1.4 GB of
source - measured from the pristine tarball, 97288 files - plus 281 MB of git
objects).**

```sh
cd /root/terratec/kernel/linux-6.18.55
git status --porcelain            # must be empty: everything is committed
make clean                        # drops .o/.ko/vmlinux, keeps source + .git
du -sh .                          # ~1.7 G (1.4 G source + 281 M of .git)
make modules_prepare -j$(nproc)   # re-run when you want to build the kit again
```

`make clean` removes `Module.symvers` and the kbuild helpers, so a later
out-of-tree build needs `make modules_prepare` first (a couple of minutes). The
git history stays, so the branches are still there.

Before either, confirm nothing is uncommitted:

```sh
git -C /root/terratec/kernel/linux-6.18.55 status --porcelain
git -C /root/terratec/kernel/linux-6.18.55 log --oneline 941c14e58..phase88-alt-single
```
