#Requires -Version 5.1
<#
.SYNOPSIS
    Put the ai-box autoinstall answer file on an Ubuntu Server USB stick, and make
    that stick install unattended.

.DESCRIPTION
    Expects a stick written by Rufus in ISO Image mode, where the ISO's files sit on
    an ordinary writable FAT32 volume (the folder that holds casper\, boot\ and EFI\).

    Does three things:
      1. refuses the stick unless it looks like that (a DD Image mode stick is a
         read-only ISO9660 image -- there is nowhere to put the file),
      2. refuses an unfilled answer file (placeholder password or SSH key),
      3. writes autoinstall.yaml at the stick's root, LF endings, no BOM, and adds
         `autoinstall` to every `linux` line in boot\grub\grub.cfg, before its `---`.

    The kernel argument is the belt to the file's braces: with `autoinstall` on the
    command line subiquity starts autoinstall for certain and says so loudly when it
    cannot find the file, instead of quietly offering the interactive installer.
    Anything after `---` on that line is not passed to the kernel, which is why the
    argument goes before it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\windows-seed-usb.ps1 -Root D:

.EXAMPLE
    .\scripts\windows-seed-usb.ps1 -Root E: -Config .\autoinstall\user-data -Force
#>
[CmdletBinding()]
param(
    # Stick root: "D:" or "D:\" or a path.
    [Parameter(Mandatory = $true)]
    [string]$Root,

    # The answer file to install on the stick. Default: this repo's autoinstall/user-data.
    [string]$Config,

    # Replace an autoinstall.yaml that is already on the stick.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably set while binding parameters, so default here instead.
if (-not $Config) {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Config = Join-Path $here '..\autoinstall\user-data'
}

if ($Root -match '^[A-Za-z]:$') { $Root = "$Root\" }
if (-not $Root.EndsWith('\')) { $Root += '\' }
if (-not (Test-Path -LiteralPath $Root)) { throw "No such path: $Root" }

# --- 1. is this an ISO Image mode stick? -------------------------------------
foreach ($dir in 'casper', 'boot', 'EFI') {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $dir))) {
        throw @"
$Root does not look like an Ubuntu Server stick written in ISO Image mode
(no '$dir' folder at its root).

A stick written in DD Image mode is a read-only ISO9660 image, so there is nowhere
to add autoinstall.yaml. Rewrite it with Rufus and choose "Write in ISO Image mode",
or use the two-stick CIDATA route in docs/02-os-install.md.
"@
    }
}

# --- 2. is the answer file filled in? ----------------------------------------
if (-not (Test-Path -LiteralPath $Config)) { throw "Answer file not found: $Config" }
$text = Get-Content -LiteralPath $Config -Raw -Encoding UTF8
if ($text -match 'REPLACEME') {
    throw "$Config still has a placeholder (REPLACEME). Set identity.password and ssh.authorized-keys first -- docs/02-os-install.md."
}
if ($text -notmatch '\$6\$[^'':]+\$') {
    throw "$Config has no SHA-512 crypt password in identity.password. Generate one: printf '%s' ""`$PW"" | openssl passwd -6 -stdin"
}

# --- 3a. autoinstall.yaml at the root of the medium --------------------------
$target = Join-Path $Root 'autoinstall.yaml'
if ((Test-Path -LiteralPath $target) -and -not $Force) {
    throw "$target already exists. Pass -Force to replace it."
}
# LF endings and no BOM: subiquity wants plain YAML, and a BOM hides the header line.
$body = $text -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($target, $body, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote $target ($($body.Length) bytes, no BOM)"

# --- 3b. autoinstall on the GRUB linux line ----------------------------------
$grub = Join-Path $Root 'boot\grub\grub.cfg'
if (-not (Test-Path -LiteralPath $grub)) {
    Write-Warning "No boot\grub\grub.cfg on the stick; left the boot menu alone. The file alone should still be picked up."
}
else {
    $linuxLines = 0
    $changed = 0
    $out = foreach ($line in (Get-Content -LiteralPath $grub)) {
        if ($line -match '^\s*linux\s') {
            $linuxLines++
            if ($line -match '\bautoinstall\b') { $line }
            else {
                $changed++
                if ($line -match '\s---(\s|$)') { $line -replace '\s---(\s|$)', ' autoinstall ---$1' }
                else { "$line autoinstall" }
            }
        }
        else { $line }
    }
    if ($changed -gt 0) {
        Copy-Item -LiteralPath $grub -Destination "$grub.bak" -Force
        # LF, not CRLF: GRUB reads this file, and the ISO's own copy uses LF.
        [System.IO.File]::WriteAllText($grub, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "patched $changed of $linuxLines linux line(s) in $grub (backup: grub.cfg.bak)"
    }
    elseif ($linuxLines -eq 0) {
        Write-Warning "No 'linux' lines in $grub -- left the boot menu alone. autoinstall.yaml at the root should still be picked up."
    }
    else {
        Write-Host "$grub already has autoinstall on all $linuxLines linux line(s)"
    }
}

Write-Host ""
Write-Host "Ready. Boot the stick; it installs to the largest disk and powers off."
