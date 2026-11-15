# mincer_ray-AGBLayered for Analogue Pocket

Original Pocket port by **mincer_ray**, based on the [MiSTer GBA core](https://github.com/MiSTer-devel/GBA_MiSTer).
**Wokann** adds **AI-generated cartridge hardware passthrough and cartridge save reading/writing features**.

原作者：mincer_ray；Wokann 基于 AI 生成并添加卡带硬件直通、卡带存档读取与写入功能。

This Layered fork runs ROMs from SD while independently routing saves and peripherals to the cartridge slot.
Peripheral Passthrough supports raw GBA GPIO and standard DS Rumble Pak adaptation without ROM ID or Force Quirk checks, including EZ 3-in-1 / EZODE rumble translation.
The peripheral switch applies live; changing Cartridge Saves still restarts the game. Force Quirk remains available for upstream local emulation.
See [LAYERED.md](LAYERED.md) for setup, compatibility boundaries and simulation coverage.

## Features

- **Filters**
- **Save States**
- **Fast Forward (Bound to Y button)**
- **Button Turbo (Bound to X button)**
- **RTC**
- **Link Cable** - 2/3/4p Multiplayer, GCN link, GBA wireless, Single Pak download
- **Rumble (DS Rumble Pak)**

## Fast Forward

You can change fast forward behavior with the "Fast Forward Render" setting in the menu. Choices are:

- Fastest: core runs as fast as possible, highest possible fast forward speed but can show tearing/mixed/corrupted frames in some games.
- Stable: wait for full frames. video during fast forward is MUCH more stable, however max fast forward speed is decreased.

## RTC and Save Compatibility

NEW (0.8.0 and above): RTC timestamp is now saved as an external .rtc file next to the .sav. This should increase save compatibility with other cores and emulators since the .sav now presents as correctly sized. Downgrade flow is included so on updating to a version of the core with the new feature, the core should correctly update your saves as well.

LEGACY (0.7.1 and below): When a game uses RTC (either detected automatically or forced on), the core appends RTC data to the end of the save file. This makes the save file larger than a standard GBA save. If you then try to load that save on a GBA core that doesn't support RTC, it will fail with an error because the save file size doesn't match what the core expects. To use the save on a non-RTC core, you would need to trim the extra RTC bytes from the end of the file to restore it to its original size.

>For saves you might be having issues with try the new online self help tool I have added here:
>
>https://www.peterdegenaro.com/pages/rtc-save-tool.html

For save files produced by older releases, the following tools might be able to help, but I have not tested them:
- [mGBA](https://mgba.io/) — The built-in Save Converter tool (Tools → Save Converter) can export saves with RTC data stripped. Requires mGBA v0.10.3 or later.
- [save-file-converter](https://github.com/euan-forrester/save-file-converter) — A web-based tool that can convert and resize save files across many retro formats.

## **FORCE QUIRK**
At the moment there only seems to be 1 romhack that needs this feature. If you are trying to play Unbound keep reading, otherwise PLEASE ignore this feature.

— Manually enables RTC for ROMs that aren't in the database. This is useful for ROM hacks that add RTC support to games that don't normally use it. Make sure to enable this on first load of the hack, ideally as soon as possible during the bios display to avoid any issues with initializing the save. **USE WITH CAUTION:** enabling this on a game that doesn't actually use RTC can cause crashes or glitches.
### **⚠️WARNING: Forced RTC setting persists across games! Remember to turn it off before loading a game that doesn't need it⚠️**
### **⚠️WARNING: Do not enable this setting unless you are playing a romhack that needs it⚠️**

## Accuracy

This core more or less replicates the current accuracy of the MiSTer GBA core master branch. The features that were cut to fit the smaller FPGA were convenience features, not accuracy-related logic. It scores similarly to the MiSTer core in the mGBA test suite. If you encounter a game that works on MiSTer but not here, please open an issue.

Note: MiSTer core has an accuracy branch! A few of those changes have made it into this port but due to it not supporting fast forward (never coming due to technical limitations) or link port (probably coming) I've kinda stalled on that branch for the time being. I'm considering maybe splitting into 2 cores, but probably we just need to wait for the MiSTer devs to finish before really committing to that plan. The regular MiSTer core works well enough for now.

## Installation

Install this fork from the successful `layered` Actions run in this repository:

1. Download `package-layered`, then extract the contained core package ZIP
2. Copy the 3 folders `Cores/`, `Platforms/`, `Assets/`  to your SD card
   - **macOS users:** Note: macOS Finder replaces folders instead of merging them so do it all manually and be careful.
3. Place your ROMs and `gba_bios.bin` in `/Assets/gba/common/`
4. Select `AGBLayered` by `mincer_ray`. Its install folder is `/Cores/mincer_ray.AGBLayered/`: Pocket requires the folder to exactly match `metadata.author + "." + metadata.shortname`. The project title remains `mincer_ray-AGBLayered`; the description and `info.txt` credit both mincer_ray and Wokann. Existing `/Saves/gba/common/` files remain shared; core settings and Memories belong to the new core identity.

The following sections describe inherited upstream features. Force Quirk is unnecessary for the Layered physical peripheral route.

## Known Issues

- **Fast forward speed varies by game** — Games that make heavy use of the GBA's slower external RAM will not fast-forward as quickly as games that primarily use internal RAM. This is most noticeable with the Classic NES Series titles.

- **Fast forward creates visible screen tearing** — Nothing i can do about this for the time being. Would need a frame buffer.

- **64MB Video carts do not work** you cant watch shrek, shrek 2, or shark tale =(

## Building from Source

Should be very easy

### Prerequisites

- Docker
- `raetro/quartus:21.1` Docker image

### Build

```bash
./scripts/build.sh
```

## Credits

- **[MiSTer GBA core](https://github.com/MiSTer-devel/GBA_MiSTer)** — original FPGA GBA implementation
- **[Analogue openFPGA](https://www.analogue.co/developer)** — platform framework and core template
- **[budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)** — reference for MiSTer-to-Pocket porting patterns
- **[agg23](https://github.com/agg23)** — analogue-pocket-utils and reference SNES/NES Pocket cores

## License

GPL-2.0 — see [GBA_MiSTer LICENSE](https://github.com/MiSTer-devel/GBA_MiSTer/blob/master/LICENSE) for details.
