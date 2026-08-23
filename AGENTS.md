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
