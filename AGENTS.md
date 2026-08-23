# Working on omarchy-vm

Guidance for agents changing this code. What the tool *does* is in `README.md`;
this file is about how to change it without breaking things quietly.

## Build and sign, always together

```sh
./build.sh
```

`swiftc` alone produces a binary that dies the instant it touches
`VZVirtualMachine`, because Virtualization.framework requires the
`com.apple.security.virtualization` entitlement and an unsigned binary does not
have it. If you compile by hand while debugging, sign by hand too.

## A change is not done until a guest booted with it

This program's failure modes do not show up in a compile or a unit test. They
show up as a guest that boots and then behaves strangely several minutes later.
So verify by running it:

```sh
./omarchy-vm --cpus 6 --memory 12
```

and then confirm from *inside* the guest — over SSH once it has `sshd`, or by
reading `vm/console.log`. Check `uptime`'s load average and instantaneous CPU
(`top -b -n 2` and read the **second** sample; the first, and anything from
`ps`, is an average over the process's life and will mislead you right after a
stall).

Take a restore point first, so a bad change costs nothing:

```sh
./restore.sh save before-my-change
```

## The console pty is load-bearing

The guest's console is a host pty, and **something must keep reading it**. A pty
whose buffer nobody empties blocks its writer; the writer here is the guest's
console; and a blocked console wedges every process that prints. The symptom is
not "the console is broken" — it is a guest whose load average climbs into
double digits, whose services time out, and which stops answering SSH, all for
reasons that look unrelated. `drainConsole` exists for this. Do not remove it,
and if you change the serial attachment, make sure whatever replaces it is still
drained.

## Diagnosing a guest that looks hung

Two host-side signals are worthless here, and both look convincing:

- **An open TCP port proves nothing.** The NAT completes handshakes for ports
  with nothing behind them — a connect to port 12345 succeeds just as well as to
  22. Read a service banner instead (`nc host 22` should print `SSH-2.0-...`).
- **`ps` `%cpu` is a lifetime average.** A process that spun for four minutes and
  has since gone idle still reports a high number for a long time.

`arp -an` does tell you which guest addresses are real, because it is answered by
the guest's own interface rather than by the NAT.

## Never commit

`vm-key*` (the SSH key that reaches into the guest), `archboot-key`, `vm/`
(64 GB sparse disk images and per-machine EFI variables), `iso/`, and the built
binary. `.gitignore` covers these; check `git status` before committing anyway,
because a stray key in a public repo is not undoable by deleting it later.

## Guests are aarch64 only

Virtualization.framework has no instruction translation. An x86_64 image cannot
boot here no matter how it is configured, and Rosetta for Linux does not change
that — it translates user-space binaries inside an already-ARM64 guest. Before
planning around an ISO, check that it contains `EFI/BOOT/BOOTAA64.EFI`.

## When screenshots stop working

macOS grants Screen Recording **per executable**, and Claude Code ships a new
executable on every update, so the grant lapses on a version bump. What you see
is `could not create image from window` — which reads like a window problem and
is not one. Run `./check-capture.sh`; it names the entry to switch on.

Do not chase these, they are the same missing grant wearing different clothes:

- `CGWindowListCopyWindowInfo` reporting **empty window titles**
- the same call reporting **`sharing=0`** for every window
- failures arriving in **multi-minute all-or-nothing blocks** (a prompt answered
  "allow once" buys a short working window, which makes it look random)

The one signal worth reading is ScreenCaptureKit's error: **`-3801`**,
`SCStreamErrorDomain`, "The user declined TCCs for application, window, display
capture". That is the grant, stated plainly.

A control matters here: capture a second, unrelated window in the *same* sample.
If both fail together, it is the grant and nothing else. Testing one window at a
time, or comparing samples taken minutes apart, will send you somewhere else.

Entries named `claude` or `Claude` in that settings pane are different programs;
switching them on does not help. The entry you need is named after the running
version, e.g. `2.1.241`.

## Do not go looking for GPU acceleration

There is none for Linux guests, and it is not a setting. `VZVirtioGraphicsDeviceConfiguration`
exposes only `scanouts`; the guest kernel reports `[drm] features: -virgl`, i.e. the
device never advertises 3D. Mesa already ships `virtio_gpu_dri.so` and would use it
if it were offered, so a missing driver is not the explanation either. The only
lever is drawing fewer pixels — see the note at the top of `README.md` before
spending time here.
