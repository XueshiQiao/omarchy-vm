# omarchy-vm

A small macOS host for running an **aarch64 Linux** guest on Apple's
Virtualization.framework, built to install Arch Linux ARM in a VM on Apple
Silicon and drive it headlessly.

It is about 300 lines of Swift. There is no configuration file: everything is a
command-line flag, and all guest state lives in one directory you can copy.

## Requirements

- An Apple Silicon Mac
- Xcode (for `swiftc` and `codesign`)
- An **aarch64** Linux ISO that boots via EFI

## Build

```sh
./build.sh
```

The build signs the binary with the `com.apple.security.virtualization`
entitlement. Without it the process dies the moment it touches
`VZVirtualMachine`, so do not run `swiftc` on its own and wonder why.

## Run

Install from an ISO:

```sh
./omarchy-vm --iso path/to/installer.iso --cpus 6 --memory 12 --disk 64
```

Then boot the installed system by leaving `--iso` off:

```sh
./omarchy-vm --cpus 6 --memory 12
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `--iso <path>` | none | Attach an installer image as USB mass storage |
| `--cpus <n>` | 6 | Virtual CPUs |
| `--memory <gb>` | 12 | RAM in GB |
| `--disk <gb>` | 64 | Disk size, created sparse on first run |
| `--width` / `--height` | 1920 / 1200 | Guest display size |
| `--bundle <dir>` | `~/Code/omarchy-vm/vm` | Where guest state lives |

The bundle directory holds `disk.img`, the EFI variable store, the serial log,
and the path of the console device.

## Restore points

The disk is a single file on APFS, so a snapshot is a clone: instant, and it
costs no space until the two copies diverge.

```sh
cp -c vm/disk.img vm/disk-before-something-risky.img   # snapshot
./restore.sh disk-before-something-risky               # roll back
```

`restore.sh` refuses to run while the VM is up, and keeps a copy of whatever it
replaces, so a mistaken restore is itself undoable.

## Getting a shell in the guest

The serial console is a real two-way pty. Its device path is printed at startup
and written to `vm/serial.pty`; everything the guest prints is appended to
`vm/console.log`.

```sh
cat vm/console.log            # what the guest has said
printf 'uname -a\n' > "$(cat vm/serial.pty)"   # type at the guest
```

Once the guest has `sshd`, prefer SSH. It is faster and survives the guest's
console being busy.

## Things that cost time to learn

**An x86_64 ISO cannot boot here, at all.** Virtualization.framework has no
instruction translation; on Apple Silicon it virtualises the native ARM CPU and
nothing else. Rosetta for Linux translates x86 *user-space binaries inside an
already-ARM64 guest* — it does not boot an x86 kernel. Check the ISO before you
plan around it: it needs `EFI/BOOT/BOOTAA64.EFI`, not `BOOTx64.EFI`.

**Something must drain the serial pty.** A pty whose buffer nobody empties
blocks its writer, and the writer is the guest's console. Leave it undrained and
every process that prints wedges: services time out, load average climbs into
double digits, and the guest looks hung for reasons unrelated to what it was
doing. This program now drains its own console, which is why it is safe to
ignore.

**The NAT answers TCP for addresses and ports that have nothing behind them.**
A connect() to a port nobody is listening on still succeeds, so "the port is
open" proves nothing about the guest. Read a banner, or check the ARP table for
which addresses are real.

**`kmscon` is a poor fit for this guest.** Arch installers may set it as the
console; it renders text through the GPU, so on a virtual display it burns CPU
continuously and depends on `localed` over D-Bus. A plain `getty@tty1` costs
nothing:

```sh
systemctl disable --now kmsconvt@tty1
systemctl enable --now getty@tty1
```

## `vmctl.sh`

Drives the guest by sending key events to the VM window, for the window between
"the installer is on screen" and "the guest has sshd". It needs a helper that
can screenshot one window by id (`APPSHOT`) and macOS Accessibility permission.
Once SSH works, stop using it.
