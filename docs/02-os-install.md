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
| llama-server / ComfyUI / Open WebUI | identical | identical |
| Swap | **none created by default** | zram by default |

**Use Server** unless this box will also be somebody's desktop. Nothing in this repo needs a
display: `llama-server`, ComfyUI and Open WebUI are web services, and `vulkaninfo`, `rocminfo`
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
    libvulkan-dev vulkan-tools mesa-vulkan-drivers glslc libssl-dev
pipx ensurepath                       # then log out and back in so `hf` is on PATH
pipx install "huggingface_hub[cli]"   # the `hf` CLI, for pulling model files by hand
sudo sensors-detect --auto
```

`pciutils` matters on Server — `lspci` is not installed by default, and both the preflight
script and every GPU diagnosis here start with it.

`libssl-dev` matters for a different reason: `llama-server` downloads GGUFs by itself (the
`-hf` flag, `POST /models`, and the download buttons in the web UI) with its own HTTPS client.
Without OpenSSL headers CMake still builds happily, and then every `https://` request from the
server fails before it leaves the box.

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

## Unattended install (autoinstall)

Yes. Ubuntu Server's installer (subiquity) reads a YAML answer file and can install with nobody
at the keyboard. It is the `autoinstall` format Canonical documents as "unattended",
"hands-off" or "preseeded", supported since 20.04 and current on 26.04. `autoinstall/user-data`
in this repo is a ready answer file for this machine: hostname `ai-box`, user `ai-user`, OpenSSH
with keys only, whole-disk ext4, DHCP on Ethernet (a fixed address is three lines away, see
"Static address instead of DHCP" below), the toolchain from the next section pre-installed, and
the Phase 2 GRUB arguments already applied.

### What still needs a human

Neither of these is an installer menu:

1. **BIOS** — the 512 MB iGPU carve-out and the boot order ([01](01-hardware-and-bios.md)). No
   answer file can do that.
2. **The seed medium** — the answer file has to reach the installer, and getting it there is
   the one piece of preparation: one file added to the installer stick itself (Windows, below),
   a second USB stick, a repacked ISO, or PXE.

Plus two values of your own, once: a password hash and your SSH public key.

### Two USB sticks (Linux)

```bash
# 1. installer USB, as usual
sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/sdX bs=8M status=progress oflag=direct

# 2. seed USB: any small stick. The volume label must be exactly CIDATA and it must be
#    the FIRST partition — cloud-init looks for the label, not the device.
sudo wipefs -a /dev/sdY
sudo mkfs.vfat -n CIDATA /dev/sdY1
sudo mount /dev/sdY1 /mnt
sudo cp autoinstall/user-data autoinstall/meta-data /mnt/
sudo umount /mnt
```

Fill in your own values in `autoinstall/user-data` before copying it:

```bash
read -rsp 'login password: ' PW; echo
printf '%s' "$PW" | openssl passwd -6 -stdin     # -> identity.password (keep the quotes)
cat ~/.ssh/id_ed25519.pub                         # -> ssh.authorized-keys
```

Boot the installer USB. At the GRUB menu highlight **Try or Install Ubuntu Server**, press
**`e`**, append ` autoinstall` to the `linux` line, press **Ctrl-X**. That keypress is the only
interaction, and it is deliberate: subiquity will not wipe a disk from a stray seed USB unless
`autoinstall` is on the kernel command line. Without it you get the prompt
*"Continue with autoinstall? (yes|no)"*, which is exactly the thing to avoid.

When it finishes the machine **powers off**; it does not reboot, because the installer USB is
still first in boot order and a reboot would reinstall it in a loop. Pull both sticks, power on.

### From Windows (the ISO is on the Windows machine)

**One stick is enough** — use this if you only own one. The reason it works is Rufus's two
writing modes: **ISO Image mode** puts the ISO's *files* on an ordinary writable FAT32 stick, so
anything left over after the write can be added; **DD Image mode** copies the ISO bit for bit and
leaves a read-only ISO9660 volume with nowhere to put anything. The answer file only has to be
one of those files.

1. [Rufus](https://rufus.ie): *Device* = the stick, *Boot selection* =
   `ubuntu-26.04-live-server-amd64.iso`, *Partition scheme* GPT / *Target system* UEFI,
   **START**, and when it offers *ISO Image mode / DD Image mode* take **ISO Image mode** (the
   default). Check the download first, since a corrupt ISO installs a corrupt system:
   `certutil -hashfile ubuntu-26.04-live-server-amd64.iso SHA256` against the checksum on the
   Ubuntu download page.
2. Fill in the two values in `autoinstall\user-data` (below), then put it on the stick as
   `autoinstall.yaml`, at the **root** — the same folder that holds `casper\`, `boot\` and
   `EFI\`. The helper checks the stick first and does the copy (use your stick's letter):

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\windows-seed-usb.ps1 -Root D:
   ```

   or, by hand:

   ```powershell
   Copy-Item .\autoinstall\user-data D:\autoinstall.yaml
   ```

   Subiquity reads a file from the **installation medium** directly, so there is no `CIDATA`
   label to get right, no second stick, and no keystrokes at all — it does not even ask
   *"Continue with autoinstall? (yes|no)"*, because that prompt exists to stop a stray seed from
   wiping a disk and a file sitting inside the medium is not that. The `#cloud-config` first
   line is a plain YAML comment and is ignored in this position; `meta-data` is only used by
   the cloud-init route, so it is not needed here.
3. Boot the stick (F12 for this board's boot menu) and walk away. It installs, then powers off.

**If it boots to the interactive installer,** subiquity never saw the file, and the cause is
almost always visible in Explorer: `casper\`, `boot\`, `EFI\` and `autoinstall.yaml` must sit
side by side at the stick's root. A **DD Image mode** stick shows no folders at all (Windows may
even offer to format it), `autoinstall.yaml.txt` is a different file (`dir /x` shows the real
name), and a copy dropped into a subfolder is not at the root either. The helper above checks
all three, and it also adds `autoinstall` to the `linux` line in `boot\grub\grub.cfg` — before
that line's `---`, because everything after `---` is not passed to the kernel. With the argument
present subiquity starts autoinstall for certain and says so loudly when the file is missing,
instead of quietly falling back to the menus.

If that stick does not boot, write it again in DD mode — and then you do need a second stick,
because DD mode leaves you no room for `autoinstall.yaml`.

**If you do have a second stick,** the seed route still works from Windows. The seed stick only
has to be FAT32, labelled `CIDATA`, with `user-data` and `meta-data` at its root: right-click it
in Explorer > **Format** > *File system* FAT32, *Volume label* `CIDATA`, *Quick format*, then

```powershell
Copy-Item .\autoinstall\user-data, .\autoinstall\meta-data -Destination E:\
```

If Explorer offers only exFAT/NTFS for that stick, `diskpart` does it (`clean` erases whatever
you point it at — read the drive number out loud first):

```
diskpart
list disk
select disk N            REM the SEED stick -- not the installer, not your SSD
clean
create partition primary
format fs=fat32 quick label=CIDATA
assign
exit
```

Then at the GRUB menu press **`e`**, append ` autoinstall` to the `linux` line (before its
`---`), and press **Ctrl-X**.

**Fill in the two values first.** Use **Git Bash** — it ships `openssl`, and neither PowerShell
nor `cmd` has a sha512-crypt tool:

```bash
read -rsp 'login password: ' PW; echo
printf '%s' "$PW" | openssl passwd -6 -stdin      # -> identity.password, keep the quotes
cat "$USERPROFILE/.ssh/id_ed25519.pub"            # -> ssh.authorized-keys
```

No key yet? `ssh-keygen -t ed25519` in the same window, then run the `cat` again. Edit
`autoinstall\user-data` in Notepad or VS Code and save it as **UTF-8 without BOM** (Windows 10+
Notepad's default; Word and WordPad will add a BOM and subiquity will not see
`#cloud-config`). CRLF line endings are fine.

### Baking it into the ISO (no keystrokes at all)

If you would rather never touch the keyboard again — reinstalling later, or a second identical
box — put an `autoinstall.yaml` at the **root of the installation medium** (the directory
holding `casper/`) and add `autoinstall` to the `linux` line in the ISO's
`boot/grub/grub.cfg`, then repack it with `xorriso`. Subiquity reads a file from the medium
directly, without cloud-init and without the confirmation prompt. You must carry the El Torito
and UEFI boot images across (`-isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin`, `-eltorito-boot
boot/grub/i386-pc/eltorito.img -no-emul-boot`, `-eltorito-alt-boot -e boot/grub/efi.img
-no-emul-boot -isohybrid-gpt-basdat`), so boot the repacked image in a VM before trusting it.
For one machine this is more work than the `e` keypress, which is why it is not scripted here.

### What the answer file does that the manual steps below would otherwise do

- `network` — one Ethernet interface matched by name (`en*`), DHCP by default. A fixed
  address goes in this same stanza, see "Static address instead of DHCP".
- `storage.layout: direct` with `match: {size: largest}` — plain ext4 on the whole 2 TB, and
  `largest` so the seed stick is never a candidate. Change `direct` to `lvm` to keep the
  interactive installer's default layout.
- `late-commands` writes `ttm.pages_limit` / `ttm.page_pool_size` for 48 GiB into
  `/etc/default/grub` and runs `update-grub`, so after the first boot `00-preflight.sh` passes
  the memory check and you can skip `sudo ./scripts/10-gpu-memory.sh 48`. It also adds
  `ai-user` to `render,video` (otherwise a `usermod` + re-login is needed).
- `shutdown: poweroff`, as above.

Deliberately **not** automated, because each needs a decision or a network fetch:
`fwupdmgr update`, `sensors-detect`, `pipx install huggingface_hub`, and the zram stanza.
Those stay manual, in the sections that follow.

### Static address instead of DHCP

`dhcp4: true` is the default and the right choice for most boxes — a DHCP reservation in the
router pins the address without putting it in two places. If the box must own a fixed address
anyway, put it in the answer file: subiquity applies it to the running installer and writes the
same stanza into the target system, so the first boot already answers on that address.

Replace `dhcp4: true` with this (the commented block in `autoinstall/user-data` is the same
thing):

```yaml
  network:
    version: 2
    ethernets:
      lan:
        match:
          name: "en*"
        addresses: # plural: `address:` is an unknown key and aborts the install
          - 192.168.150.40/24
        routes: # the supported form of the deprecated `gateway4:`
          - to: default
            via: 192.168.150.1
        nameservers:
          addresses:
            - 192.168.150.5
```

**One wrong key ends the install.** The answer file is not what netplan reads; subiquity renders
it into `/etc/netplan/00-installer-config.yaml` and runs `netplan apply`, and a schema error
there fails `Network/apply_autoinstall_config`, drops you at `An error occurred. Press enter to
start a shell`, and stops. `address:` for `addresses:` is the trap — the error reads
`Error in network definition: unknown key 'address'`, and it is easy to miss because the rest of
netplan takes singular keys. Also write the gateway as a route: `gateway4:` is deprecated in
netplan 1.x.

You do not have to re-run a 20-minute install to test a stanza. In the crash shell, subiquity's
rendered copy is already there — fix it, apply it, and silence means the stanza is valid:

```bash
sed -i 's/address:$/addresses:/' /etc/netplan/00-installer-config.yaml   # live copy
netplan apply && echo "stanza is valid"
sed -i 's/address:$/addresses:/' /cdrom/autoinstall.yaml                 # the stick
```

If the stick is mounted read-only, `mount -o remount,rw /cdrom` first. Then `reboot` to re-run
the install against the corrected file. On a system that is already installed, the same file is
`/etc/netplan/00-installer-config.yaml`: edit, `sudo netplan apply`, then `ip -br a` to confirm
— a mistake there is one error message instead of a dead installer.

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
