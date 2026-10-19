# Vendor drivers kept here

These are the reference implementations the Linux fix was derived from. Nothing
in here is ours; each file is listed with what it proved.

## `win/` - Windows, Terratec EWS88/PHASE 88 driver 5.51b (14 Mar 2007)

| file | what it was used for |
|---|---|
| `ews88wdm.sys` | the main WDM driver, disassembled into `../analysis/ews32.dis`. Gave the chip-select expander address **8-bit `0x42`** (7-bit `0x21`), the two-byte write `{0x01, flags | cs_nibble}` with initial flags `0x20`, and - the one that mattered most - the **second expander register** written as `{0x03, 0x00}` on type-8 (PHASE 88) boards. Linux never wrote that register, its latch comes up undefined and the four AK4524 keep their serial outputs tri-stated: that is why all 8 analog inputs read zeros. Type dispatch at `ews32.dis:166f9` (`cmp edx,0x8`), `[dev+0x184]` -> flag `0x20`, `[dev+0x185]` -> flag `0x10`. |
| `ews88wdm.inf` | `[PHASE88.Interface.Midi1]` **and** `[PHASE88.Interface.Midi2]` ("PHASE88 MIDI Port 1/2") - the reason the second MPU-401 UART was suspected, then measured and quirken. Changelog `history.txt:10`: `17-Sep-02 (Cl) - Mic28 Extensions (Midi 2)`. |
| `history.txt` | driver changelog (MIDI 2 tied to the Mic28 feature). |
| `EWS88-ControlPanel-5.51b.exe` | mixer app strings: `Mic InputSel`, `Codec input level`, `Codec input switches`, `Source for Record`, `LineOut12/34/56/78`, `Clock Source`. Note there is **one** mic-select control here, not per pair - which is why the Linux control is a single `Line/Mic 7/8 Switch` and not four. |
| `ews88wdm64.sys` | 64-bit variant, identical interface, not analysed. |
| `ews88wdm.cat`, `Asio88mt.dll`, `Asio88mt64.dll` | signature + ASIO drivers, kept for completeness, not used. |
| `IMPORTANT-INSTALLATION-NOTES.txt` | vendor install notes. |

## `os/` - Mac OS 9, PHASE 88 1.0.1b3

| path | what it was used for |
|---|---|
| `Applications/Phase88 Control Panel.app` | the richest description of the board: `Line/Mic 1/2 ... 7/8`, `Mic 2/8 Settings`, `Gain Levels`, `SetInputLevelSwitch`, `SetCodecInputVolume`, `Mic28SetSPDIFSrc/ADATSrc/EWSLinkSrc/LineOutSrc`, and a system clock-source select (`Get/SetSysClockSource`, `Mic28ClockSourceChanged`). The per-pair names belong to the EWS88 family, not this board - the PHASE 88 has one input switch. |
| `System/Library/Extensions/TerraPhase88Audio.kext` | kext symbols `IceAPIGetNumMIDIDevice`, `IceAPISetMidiCallback`, `TerratecServeMidiIRQ`, `NotifyClientMidiCallbackRoutine`. Binary md5 `d3cecb1fbf18756bb57d754832a66d71`. |
| `Library/Audio`, `Library/Midi Drivers`, `Bin/PHASE88RestoreSettings`, `Resources/` | OS9 glue + docs. |
| `Archive.pax`, `Archive.bom`, `PkgInfo`, `PHASE88_1.0.1b3.pkg.pax` | the package itself, so the tree above can be re-extracted. |

## Removed during the cleanup (2026-10-19)

* `os9_decompiled/` - a Ghidra project (`.rep`, 7.5 M) built from the kext
  binary above. Regenerate it from `os/System/Library/Extensions/` if needed;
  nothing in the Linux work depends on it.
* `EWS88_D_MT_App_Drv_2000_Vista_XP_5.51b/` - flattened: the control panel and
  the notes are now in `win/`, the empty `Driver 5.51b` folder and
  `V549Remove.exe` (an uninstaller) were dropped. The driver files themselves
  were already in `win/` (as `windows2000_vista_xp/`).
