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

## Desktop or Server?

Both editions ship the same kernel, the same `amdgpu` driver and the same `fwupdmgr`, so
everything in this repo works either way. The difference is what else is on the disk:

| | Server | Desktop |
|---|---|---|
| RAM left for models | ~1.5–2 GB more | GNOME plus a browser idle at 1.5–2 GB |
| Display | none — SSH only | console, Wayland/X11 |
| `glxinfo` / Mesa GL stack | not installed (irrelevant here) | present |
| llama-server / ComfyUI / bot | identical | identical |
| Swap | **none created by default** | zram by default |

**Use Server** unless this box will also be somebody's desktop. Nothing in this repo needs a
display: `llama-server`, ComfyUI and the bot are HTTP services, and `vulkaninfo`, `rocminfo`
and the `lspci`/sysfs checks all work with no session attached. What you give up is a local
browser for the ComfyUI UI and Open WebUI — the SSH tunnel in
[04-llm-stack.md](04-llm-stack.md) covers that, and it is what you want anyway when the box
sits in another room.

## Install Ubuntu 26.04 LTS

### Server install (recommended)

1. Download the **live-server** ISO and write it with Rufus (Windows) or `dd`:

   ```bash
   # on an existing Linux box, /dev/sdX = the USB stick — double-check this
   sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/sdX bs=8M status=progress oflag=direct
   ```

2. Boot it (F12 → the USB device). The installer is text-mode; you drive it at the console
   once and then never again.

3. Installer choices:
   - **Ubuntu Server**, *not* "Ubuntu Server (minimized)" — the minimized image strips
     packages the scripts need.
   - Networking: DHCP on Ethernet is fine. Skip the proxy step.
   - Storage: **Use an entire disk**, whole 2 TB. It puts LVM under the filesystem by
     default; that is harmless here, so accept it rather than fighting *Custom storage
     layout* unless you have a reason. No encryption unless you want it (LUKS works fine —
     nothing in this plan conflicts). The Server installer creates **no swap partition**,
     which is exactly what we want.
   - Profile: hostname `ai-box`, username e.g. `ai`.
   - **Install OpenSSH server: yes.** This is your only way in afterwards.
   - Featured snaps: install none. Ubuntu Pro: skip.

4. Reboot, then `ssh ai@ai-box.local` (or the DHCP address from your router) and do the rest
   of this document over SSH.

### Desktop install (only if you want a screen on it)

1. Download the **desktop** ISO (`ubuntu-26.04-desktop-amd64.iso`) and write it the same way.

2. Boot the stick (F12 → the USB device). **Try Ubuntu** first if you want to confirm the
   Wi-Fi, display and Ethernet all come up.

3. Installer choices:
   - **Normal installation**; no third-party driver checkbox needed (no dGPU, no NVIDIA).
   - **Erase disk and install Ubuntu**, entire 2 TB, **ext4**, no LVM, no encryption.
     (LUKS works fine if you want it — nothing in this plan conflicts.)
   - Do **not** create a large swap partition — the desktop already sets up zram, which is
     the right swap for a unified-memory box.
   - Hostname `ai-box`, user e.g. `ai`, automatic login **on** (this is an appliance, not a
     shared workstation).
   - Enable **OpenSSH server** if the installer offers it, or `sudo apt install openssh-server`
     afterwards. You will want it either way.

### Either edition: toolchain first

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y build-essential git cmake ninja-build pkg-config \
    curl wget jq htop pciutils lm-sensors fwupd pipx \
    python3-venv python3-pip \
    libvulkan-dev vulkan-tools mesa-vulkan-drivers glslc
pipx ensurepath                       # then log out and back in so `hf` is on PATH
pipx install "huggingface_hub[cli]"   # used by 60-download-models.sh
sudo sensors-detect --auto
```

`pciutils` matters on Server — `lspci` is not installed by default, and both the preflight
script and every GPU diagnosis here start with it.

### Firmware update

Do this **before** installing anything else (PSU plugged in, do not interrupt):

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

### Verify the platform

```bash
uname -r                                   # >= 6.18.4, expect 7.x
lspci -nn | grep -Ei 'vga|display'          # Radeon 8060S [1002:...]
ls -l /dev/kfd /dev/dri/renderD*            # needed by ROCm and torch
cat /sys/class/drm/card*/device/uevent | grep -E 'PCI_ID|DRIVER'
vulkaninfo --summary | head -30             # one AMD/RADV device, works with no display
```

`/dev/kfd` missing is the one thing to stop on: it means the `amdgpu`/KFD stack did not come
up, and ROCm will not work.

**Over SSH, `glxinfo -B` fails with "unable to open display"** — that is expected, not a GPU
fault. `glxinfo` needs a running X/Wayland session, so on a Server install it is simply the
wrong tool; on Desktop it only works at the console or with
`DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority`. Use the sysfs / `lspci` / `rocminfo` /
`vulkaninfo` checks above instead; `scripts/00-preflight.sh` detects the missing session and
skips GL checks automatically.

## Swap: zram, not a swap partition

Neither edition should get a big disk swap file. On a unified-memory box the swap device and
the GPU fight over the same 64 GB, and slow swap only turns an out-of-memory kill into a
30-second stall first. A compressed RAM disk (zram) is the right tier: it absorbs the
occasional spike — a Flux job next to the LLM, a `pip install` — without touching the SSD.

Check what you have:

```bash
swapon --show      # Desktop: /dev/zram0 at priority 100. Server: usually nothing at all.
free -h
```

If it is empty (the normal case on Server), add it:

```bash
sudo apt install -y systemd-zram-generator
sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
# A spill buffer, not a second 16 GB of memory. Do not oversize it.
zram-size = min(ram / 4, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
sudo systemctl daemon-reload
sudo systemctl start dev-zram0.swap     # or just reboot
zramctl && swapon --show
```

Keep it modest on this machine: compressed pages still live in RAM, so an oversized zram is
just a slower way to run out of memory. If `llama-server` or ComfyUI ever gets OOM-killed,
the fix is a smaller model or context, never a bigger swap.

## Storage layout

A simple, roomy layout beats a clever one here:

```
/            2 TB ext4 (whole disk)
/home/ai/ai  model library and builds (~1.5 TB of headroom after the OS)
```

If you accepted LVM in the Server installer, `/` is a logical volume spanning the disk — same
thing for our purposes, no further partitioning needed.

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

## Graphics notes

- **On Server there is no Mesa GL user-space stack, and that is fine.** The kernel driver,
  `/dev/kfd`, `/dev/dri/renderD*` plus Vulkan (`vulkan-tools` + `mesa-vulkan-drivers`, both
  in the package list) are enough for compute. ROCm's runtime talks to `/dev/kfd` directly,
  and torch's ROCm wheels carry their own user-space libraries.
- **Mesa 25.x or newer** is what you want on Desktop (26.04 ships newer). Big gains landed
  from 6.14/Mesa 25.0 onward.
- Wayland works; X11 also works. Nothing in this repo cares.
- Wi-Fi (MT7925) and Bluetooth work out of the box on Ubuntu/Fedora/Bazzite. Occasional
  reports of BT disappearing after updates — if it happens, `rfkill`, then reboot, then
  check `dmesg | grep -i mt7925`. **On Server the installer only configures Ethernet**; Wi-Fi
  needs a `netplan` stanza by hand. Use a cable for this build.
- The 5 GbE port has community reports of being **invisible on cold boot** and appearing
  after a warm reboot. If Ethernet is missing: reboot once before debugging drivers.

## What to install next

Continue with [03-gpu-memory.md](03-gpu-memory.md) — do not install a Python ML stack before
the GPU can see more than 32 GB.
