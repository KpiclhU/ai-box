# 02 — OS install

## Which distribution

| Distro | Kernel | Verdict |
|---|---|---|
| **Ubuntu 26.04 LTS** | 7.0 | **Recommended.** On AMD's ROCm compatibility matrix, well past the 6.18.4 Strix Halo fix line, LTS support, `fwupdmgr` and `amd-ttm` both trivial |
| Fedora 43 | ≥ 6.18.4 | Framework's own "best experience" pick and it ships the needed kernel fixes natively; ROCm packages are less officially blessed |
| Bazzite | ≥ 6.18.4 | Easiest out-of-the-box desktop (Wi-Fi/BT verified by Framework), but an immutable base makes the ROCm/Python stack more awkward |
| Arch / NixOS | rolling | Fine if you already live there; more setup work for Wi-Fi and ROCm |

Two kernel thresholds matter:

- **6.11 minimum / 6.15+ recommended** for the Radeon 8060S to be usable (Framework).
- **≥ 6.18.4** for ROCm's Strix Halo KFD fixes. Ubuntu 26.04 (7.0), Fedora 43 and Arch all
  clear this today.

Do not install an older LTS and then try to bolt a new kernel on unless you enjoy that.

## Install Ubuntu 26.04 LTS

1. Download the desktop ISO, write it with Rufus (Windows) or `dd`/balenaEtcher:

   ```bash
   # on an existing Linux box, /dev/sdX = the USB stick — double-check this
   sudo dd if=ubuntu-26.04-desktop-amd64.iso of=/dev/sdX bs=8M status=progress oflag=direct
   ```

2. Boot the stick (F12 → the USB device). Choose **Try Ubuntu** first if you want to confirm
   the Wi-Fi, display and Ethernet all come up.

3. Installer choices:
   - **Normal installation**, no third-party driver checkbox needed (no dGPU, no NVIDIA).
   - **Erase disk and install Ubuntu**, entire 2 TB, **ext4**, no LVM, no encryption.
     (LUKS works fine if you want it — nothing in this plan conflicts.)
   - Do **not** create a large swap partition. Ubuntu uses **zram** by default, which is right
     for a unified-memory box: a swapfile competes with the GPU for the same RAM.
   - Hostname e.g. `ai-box`, user e.g. `ai`, automatic login **on** (this is a headless-ish
     appliance; you are not guarding state secrets on the console).

4. First boot, then:

   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo apt install -y build-essential git cmake ninja-build pkg-config \
       curl wget jq htop nvtop python3-venv python3-pip \
       libvulkan-dev vulkan-tools mesa-vulkan-drivers \
       lm-sensors fwupd
   sudo sensors-detect --auto
   ```

5. Firmware update **before** anything else (PSU plugged in, do not interrupt):

   ```bash
   sudo fwupdmgr refresh --force
   sudo fwupdmgr get-updates
   sudo fwupdmgr update
   ```

6. Verify the platform:

   ```bash
   uname -r                                   # >= 6.18.4, expect 7.x
   lspci -nn | grep -Ei 'vga|display'          # Radeon 8060S [1002:...]
   ls -l /dev/kfd /dev/dri/renderD*            # needed by ROCm and torch
   glxinfo -B | head -20                       # Mesa renderer: AMD Radeon 8060S
   vulkaninfo --summary | head -30             # one AMD/RADV device
   ```

   `/dev/kfd` missing is the one thing to stop on: it means the `amdgpu`/KFD stack did not
   come up, and ROCm will not work.

## Storage layout

A simple, roomy layout beats a clever one here:

```
/            2 TB ext4 (whole disk)
/home/ai/ai  model library and builds (~1.5 TB of headroom after the OS)
```

Model weights dominate: a single 30B Q6_K is ~25 GB, a Flux fp16 set ~34 GB, an SDXL
checkpoint 6–7 GB. Keep `~/ai/models` on the same filesystem as everything else unless you
add the second drive.

If you do add a second NVMe later, mount it at `~/ai/models` and move existing files:

```bash
sudo mkfs.ext4 -L models /dev/nvme1n1
echo "LABEL=models  /home/ai/ai/models  ext4  defaults,noatime  0 2" | sudo tee -a /etc/fstab
sudo mount -a
```

`noatime` is worth it for a directory full of multi-gigabyte files.

## Desktop/graphics notes

- **Mesa 25.x or newer** is what you want (26.04 ships newer). Big gains landed from
  6.14/Mesa 25.0 onward.
- Wayland works; X11 also works. Nothing in this repo cares.
- Wi-Fi (MT7925) and Bluetooth work out of the box on Ubuntu/Fedora/Bazzite. Occasional
  reports of BT disappearing after updates — if it happens, `rfkill`, then reboot, then
  check `dmesg | grep -i mt7925`.
- The 5 GbE port has community reports of being **invisible on cold boot** and appearing
  after a warm reboot. If Ethernet is missing: reboot once before debugging drivers.

## What to install next

Continue with [03-gpu-memory.md](03-gpu-memory.md) — do not install a Python ML stack before
the GPU can see more than 32 GB.
