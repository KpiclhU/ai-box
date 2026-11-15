# 01 — Hardware and BIOS

## The machine

| Item | Value |
|---|---|
| APU | Ryzen AI Max+ 395 — 16C/32T Zen 5, 3.0 GHz base / 5.1 GHz boost, 64 MB L3 |
| Power | 120 W sustained, 140 W boost (soldered FP11 package) |
| iGPU | Radeon 8060S — 40 RDNA 3.5 CUs, up to 2.9 GHz, 32 MB MALL, ROCm target `gfx1151` |
| NPU | XDNA 2, up to 50 TOPS (unused by this plan) |
| Memory | 64 GB LPDDR5X-8000, 256-bit, 256 GB/s, **soldered — not upgradeable** |
| Storage | 2× M.2 2280 NVMe, **both PCIe 4.0 x4**, up to 8 TB each |
| Networking | Realtek RTL8126 5 GbE, AMD RZ717 (MediaTek MT7925) Wi-Fi 7 + BT 5.4 |
| PSU | 400 W FlexATX (FSP), 80+ Gold @110 V / Silver @230 V, ATX 3.0 |
| Cooling | 6 heatpipes, 120 mm fan (Noctua NF-A12x25 by default), Honeywell PTM7958 TIM |

## M.2: which socket, and what to expect

Two sockets, each with its own four lanes straight from the APU. There is no lane sharing
and **no Gen5 anywhere** — the Strix Halo APU has no PCIe 5.0 controller.

| Socket | Linux PCI address | Use |
|---|---|---|
| Main / front (top of board) | `0000:00:03.1` | **The KingSpec 2 TB — OS + models** |
| Rear / secondary | `0000:00:02.5` | Free for a second drive later |

Notes that save time:

- **2280 only.** No 2230/2242/2260 mounting holes.
- Framework ships metal **heat spreaders** over both sockets with a captive T5 Torx screw;
  the assembly pops up when you loosen it. Peel the pad's protective film.
- A drive with a **factory heatsink** fits the front socket (remove Framework's spreader) but
  usually **not** the rear one — side-panel clearance.
- **SSD thermals are a chassis weak point:** the EC does not monitor SSD temperature, and
  drives have been reported above 100 °C under sustained load. The optional 80 mm front fan
  costs ~10 minutes and drops SSD/memory temperatures materially. Recommended if this box
  will chew through model downloads.
- The full 2 TB is yours; model weights are large but replaceable, so back up
  `~/.config/ai-box` and `~/ai/data` — not the GGUF files.

## BIOS

Enter with **F2** during boot. (**F12** is only the one-time boot menu.)

### iGPU memory

```
Advanced → iGPU Memory Configuration → Custom → iGPU Memory Size → 512 MB
```

Framework's own KB article uses exactly those names. Set it **small**, deliberately:

- Framework documents a maximum GPU-addressable figure of **56 GB on a 64 GB board**
  (Windows and Linux), reachable by raising the carve-out.
- **AMD's guidance is the opposite of what most forum posts do:** keep the BIOS reservation
  small and raise the shared GTT/TTM limit from the OS. There is no measurable performance
  difference between a static carve-out and a GTT mapping on Strix Halo, and a big carve-out
  permanently removes RAM from the OS.
- There is also a Framework firmware issue: **large custom carve-outs have been reported to
  kill USB-C/USB-A ports after resume.** Small carve-out avoids the class of bug entirely.

So: BIOS 512 MB, OS-level TTM ~48 GiB. That gets you the same GPU-addressable ceiling with
none of the side effects. See [03-gpu-memory.md](03-gpu-memory.md).

### Other settings

- **Above 4G Decoding / Re-Size BAR:** leave at firmware defaults. Nothing in this plan
  requires changing them, and the menu labels on this board differ from generic AMD CBS
  guides (`Advanced → AMD CBS → NBIO → GFX Configuration → UMA Frame Buffer Size` is a
  different board family).
- **Secure Boot:** can stay enabled. The `amdgpu` driver is in-tree and signed by Ubuntu;
  ROCm user-space libraries are not kernel modules.
- **Power limits are not in the BIOS.** They follow the OS platform profile:
  `performance` = 140 W boost / 120 W sustained, `balanced` = ~100 W sustained,
  `power-save` ≈ 50 W. Set `performance` on the box that will run inference
  ([08-operations.md](08-operations.md)).

### Firmware updates

LVFS/fwupd works on this machine, and you can also update from a USB stick in the BIOS.

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update          # keep the PSU plugged in; never interrupt power
```

BIOS **3.06** or newer fixes an iGPU-memory cap bug on large-memory boards. Do this before
you spend time on GPU memory tuning.

## Assembly order

1. PSU off and unplugged, side panel off.
2. KingSpec into the **front** M.2 socket, heat spreader back on, T5 snug (not gorilla-tight).
3. Optional 80 mm front fan, blowing in.
4. Connect monitor to **DisplayPort** or HDMI on the APU, keyboard, Ethernet.
5. First boot → F2 → check BIOS version and iGPU Memory Size → save → boot the USB installer.

## Thermal expectations

| State | Typical |
|---|---|
| Idle | ~4 W SoC, ~12 W at the wall, ~31 °C |
| Sustained 120 W CPU | ~79 °C package at 23 °C ambient |
| Phoronix 230-benchmark average | CPU ~68 W avg, ~116 W peak, wall 100–104 W avg / ~180 W peak |

The 120 mm fan is audible at 100 % but the stock cooler is sufficient; extra fans buy
temperatures, not performance.
