# How to send the PHASE 88 patches upstream

Everything is prepared in `/root/terratec/upstream/`:

```
upstream/alt-single-switch/series/          RECOMMENDED SET: six patches, one Line/Mic control
upstream/series/                            the same six, but with FOUR Line/Mic controls
upstream/0000-cover-letter.patch  etc       the [PATCH 0/6] message (body needs your name)
upstream/phase88-fix.patch                  all six as one file (not for sending)
upstream/CHANGED-FILES.md                   which files changed and how much
upstream/cover-letter.txt                   the cover-letter text to paste in
upstream/msg/                               the commit messages as plain text + seqedit.py
upstream/do-not-send/                       the RFC debug-controls patch, kept out on purpose
```

Kernel tree: `/root/terratec/kernel/linux-6.18.55`.  Two branches, identical
except for patch 0005:

| branch | patch 0005 | series | on this machine |
|---|---|---|---|
| `phase88-alt-single` | one `Line/Mic 7/8 Switch` | `upstream/alt-single-switch/series/` | yes - built, installed, both cards verified |
| `phase88` | four `Line/Mic 1/2 ... 7/8 Switch` | `upstream/series/` | no |

Submission set on either branch = `941c14e58..HEAD~1` (six commits).  `HEAD` is
the RFC debug commit and must stay out.

`checkpatch.pl --strict` on the recommended set, per patch: only
`ERROR: Missing Signed-off-by: line(s)` (your step, section 1) and two
CHECKs left in - `(0x42>>1)` spacing in `ews.h` (deliberate: it matches the
neighbouring EWS macros) and `Avoid CamelCase: <ICE1712_CFG_2xMPU401>` (a macro
that already exists in `ice1712.h`).  No warnings.

## 0. The one open choice: patch 0005 (both versions are ready)

The original patch 0005 registered **four** controls (`Line/Mic 1/2 ... 7/8
Switch`) but only one of them is measurable: bit `0x10` of expander page `0x03`
raises channels 7/8 by +40.8 dB / +30.3 dB with a microphone.  Sweeping the
other bits (`0x11 0x12 0x14 0x18 0x30 0x50 0x90`) changed nothing, the Windows
driver disassembly treats **one** boolean (`[dev+0x185]`) for this board, and
you confirmed the switch works on both cards.

So `phase88-alt-single` collapses it to a single `Line/Mic 7/8 Switch` and says
why in the message.  That is the set to send unless you disagree - shipping
three knobs that provably do nothing is what a maintainer would ask you to drop
on the first review.  Both are packaged; picking the other one is only a matter
of sending `upstream/series/` instead.

## 1. Put your identity on the commits (required)

Every commit is currently authored by `root <root@debian.lab.local>`. The
list will ignore or bounce that. You also need a `Signed-off-by` trailer (the
Developer Certificate of Origin - it says you have the right to submit this
code; no legal signature, just a line).

```sh
cd /root/terratec/kernel/linux-6.18.55
git config user.name  "Your Name"
git config user.email "you@example.com"

# rewrite author and add Signed-off-by on all commits above the baseline
git rebase --exec 'git commit --amend --no-edit --reset-author -s' 941c14e58
```

Check:

```sh
git log --format='%h %an <%ae>%n%B' 941c14e58..HEAD~1 | head -40
```
Each of the six must end with `Signed-off-by: Your Name <you@example.com>` and
must *not* mention the RFC commit. Use the same address you will send from -
the `From:` of the email is taken from the patch.

## 2. Regenerate the patches (after step 0 or 1)

```sh
cd /root/terratec/kernel/linux-6.18.55
rm -f /root/terratec/upstream/series/*.patch
git format-patch --cover-letter -o /root/terratec/upstream/series 941c14e58..HEAD~1
```

Fill in `0000-cover-letter.patch`: the subject line `*** SUBJECT HERE ***` and
the body under `*** BLURB HERE ***` (a draft is in `upstream/cover-letter.txt`).

## 3. Check them

```sh
cd /root/terratec/kernel/linux-6.18.55
for p in /root/terratec/upstream/series/000[1-6]-*.patch; do
  echo "--- $p"; scripts/checkpatch.pl --no-tree --strict --no-signoff "$p" | tail -3
done
```
Last run: 0 errors, 0 warnings, 4 style checks (two continuation-line
alignments in `ews.c`, the `(0x42>>1)` spacing which matches the surrounding EWS
code, and `CamelCase` on the pre-existing `ICE1712_CFG_2xMPU401` macro). A
"Missing Signed-off-by" error only appears if you check before step 1.

## 4. Who to send to

From this tree's `MAINTAINERS` (the `SOUND` section) and
`scripts/get_maintainer.pl`:

```
To:  linux-sound@vger.kernel.org
Cc:  Jaroslav Kysela <perex@perex.cz>          (maintainer:SOUND)
Cc:  Takashi Iwai <tiwai@suse.com>             (maintainer:SOUND)
```

`linux-sound@vger.kernel.org` is the ALSA development list. The old
`alsa-devel@alsa-project.org` name survives only as the patchwork URL; do not
use it as the destination. `linux-kernel@vger.kernel.org` gets a copy through
the list - you do not have to add it.

Patch 0002 (NULL deref in `snd_ice1712_capture_open()`) is worth
`Cc: stable@vger.kernel.org` - it is a plain oops for any Envy24 board whose
AC-97 codec fails, not a PHASE 88 special. Add that line to the patch body if
you agree; a maintainer may ask for a `Fixes:` tag, which we cannot provide
honestly (the bug predates git history we can point at).

## 5. Send it

You need an SMTP account you own. Most people use `b4` (it understands
patchwork threads and `b4 send` refuses obvious mistakes):

```sh
apt install b4            # or: pipx install b4
cd /root/terratec/upstream/series
b4 send 0000-cover-letter.patch 0001-*.patch 0002-*.patch 0003-*.patch \
        0004-*.patch 0005-*.patch 0006-*.patch --dry-run      # look first
b4 send ...                                                    # then really
```

or plain git, which needs a one-time SMTP config:

```sh
git config --global sendemail.smtpserver smtp.example.com
git config --global sendemail.smtpport 587
git config --global sendemail.smtpencryption tls
git config --global sendemail.smtpuser you@example.com
git config --global sendemail.smtpPass 'app-password-here'   # or use an app-specific password
cd /root/terratec/upstream/series
git send-email --dry-run \
  --to=linux-sound@vger.kernel.org \
  --cc=perex@perex.cz --cc=tiwai@suse.com \
  --cover-letter --thread --no-chain-reply-to 00*.patch
# happy with the preview? drop --dry-run
```

Gmail/Proton/Fastmail need an **app password** (and IMAP/API enabling); some
ISPs block port 587 from a residential line, in which case send through your
provider's relay or a kernel-friendly one you pay for.

## 6. Rules that keep the submission from being ignored

* **Plain text, no attachments, no HTML.** `git send-email`/`b4` do this right;
  pasting patches into webmail does not - whitespace damage breaks `git am` and
  the bot replies with a failure.
* **One patch per message, all in one thread** under the `0/6` cover letter
  (`--thread --no-chain-reply-to` produces the right `In-Reply-To`).
* Cover letter says *why*, the patch says *what*. Keep the "what" out of it.
* Do not CC people who are not on the list without a reason; do not CC
  `stable@` on the feature patches (only patch 0002 is a fix).
* Answer review comments **inline** in a reply, and post a `v2` (with
  `[PATCH v2 1/6]`) only when you have addressed everything; describe the
  changes below the `---` line so they do not enter the commit message.
* Do not re-send because nothing happened. One review cycle is days to weeks.
  If two weeks pass, one polite reply to your own thread is enough.
* If a maintainer asks a question, the answer goes into the next version's
  commit message, not only into the email.

## 7. What to expect on this series

* The `ICE1712_CFG_NO_CON_AC97` quirk (patch 0003) is the one most likely to
  draw comment: the surrounding code has the old `Consumer PCM code does not
  work well at the moment --jk` note, and someone may prefer the consumer PCM
  devices to be suppressed differently, or want the EEPROM contents documented
  in the message. The EEPROM bytes and the `0xffff` AC-Link read are already in
  the message; that is the answer.
* Patch 0001/0004 (expander addresses, second register) are hardware facts with
  measurements behind them; the reviewable question is code shape in `ews.c`,
  not whether the board needs them.
* Patch 0006 (second MIDI port) may attract "is the second UART really wired?"
  - the loopback test result and the Windows INF section are in the message.
* Track it at `https://patchwork.kernel.org/project/linux-sound/list/` once the
  mail is through the list.

## 8. Nothing else leaves this machine

Do not send: the RFC debug-controls commit, the test scripts, the OS9/Windows
drivers (they are Terratec's property and only describe hardware), `asound.conf`
or the systemd unit. If a reviewer asks *how* a bit was found, describe the
method in a reply; the tools stay here.
