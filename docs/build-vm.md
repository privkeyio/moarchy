# The build VM

Building and checking an image means running privileged containers: `arch-chroot` mounts, loop devices, the negative test's planted defects. `scripts/vm/vm.sh` runs them inside a throwaway KVM virtual machine instead of on your machine. Inside, the image steps of CI (`.github/workflows/image.yml`) run in CI's order: the in-repo packages, the published ones, the release image and its verify, the QML tests, the PIN door test, the negative test, and the dev image with its own verify and negative test. CI's first step, the unit tests (`scripts/style-check.sh` and the two `image/boot` tests), needs no privilege and is not repeated in the VM; run it on your machine.

CI already does all of this on a fresh GitHub runner for every pull request. The VM is for building and flashing locally without giving a build root on your own machine.

## What you need

An x86_64 Linux machine with KVM, and `qemu-system-x86_64`, `qemu-img`, `passt`, `xorriso`, `gpg`, `curl`, `git` and `python3`. About 30 GB free for the disk the VM grows into (it is sparse, capped at 150 GB), and 12 GB of memory while it runs. Nothing runs as root on the host: no libvirt, no sudo, no Docker.

## Use

```sh
scripts/vm/vm.sh fetch-base                          # once: the pinned Arch cloud image, checked
scripts/vm/vm.sh build HEAD ~/.ssh/id_ed25519.pub    # a fresh VM, the build, the images out
```

On a 16-thread allowance, a build in a fresh VM took about 2 hours, most of it the kernel compiling under arm64 emulation; one reusing a VM's kernel cache (`VM_REUSE=1`, below) took about 45 minutes.

`build` takes a commit of this repo from after the build VM existed, and builds it with that commit's own `scripts/vm/in-vm-build.sh`. Each build gets a VM of its own: a fresh disk and a new host key, first boot, `check-isolation`, the build, the images copied out, power off. Nothing one build does can reach the next, its kernel cache included.

Give it a public key and the dev image is keyed to it (`docs/structure.md` I5) and copied out with the release image; without one, the dev image is built and checked with a throwaway key, as CI does, and stays in the VM. The build is followed as it runs, and fails on anything CI's image steps would fail on, with one exception: verify.sh's online-resize check needs a native arm64 kernel, so under the VM's emulation that one FAIL is allowed, and CI checks it.

The images land in `~/.local/share/moarchy-build-vm/out/<commit>-<time>.<id>/{release,dev}`. Flash one with `scripts/vm/flash-sargo.sh <directory>`, the script from this repo, never the `flash.sh` a build writes into its own output: anything that comes out of the VM is data to check, not a program to run. Only the four expected files come out, each copied by name as plain bytes with a size cap, and `SHA256SUMS` must name exactly the three images. The checksums prove the files arrived as the VM wrote them, and nothing more.

One build runs at a time per state directory, and `build` will not touch a VM that is already running. The steps also run one at a time, to look around in a VM: `setup`, `start`, `wait`, `check-isolation`, `ssh`, `stop`, `destroy`. `VM_REUSE=1 vm.sh build ...` builds in the VM that is already running, with its kernel cache, which is faster and trusts every ref built in that VM since its last `setup`.

Everything the VM keeps (its base image, keys, disk and output) is under `$MOARCHY_VM_DIR`, by default `~/.local/share/moarchy-build-vm`, mode 0700, and never in the repo. `VM_CPUS`, `VM_MEM`, `VM_DISK`, `VM_PORT` and `VM_DNS` override the defaults at the top of `vm.sh`. By default the VM gets at most 16 CPUs and QEMU runs at nice 10, so a build leaves the rest of the machine usable.

What goes in is a git bundle of the commit, which carries the history behind it too, unpushed commits included, and the public key if you gave one.

## What the isolation is, and is not

- **The host's loopback is unreachable.** passt runs with `--map-host-loopback none`, under which packets the guest sends to the host's loopback are dropped (passt(1)). `check-isolation` tests that on your machine: it puts listeners on `127.0.0.1` and `::1`, has the guest try its IPv4 and IPv6 gateways, and fails if either listener logs any connection at all. The verdict is the host's, not the guest's, and the guest's own HTTPS has to work, so a dead network cannot pass for isolation.
- **Everything else on your network is reachable, this machine included.** passt opens the guest's connections as ordinary sockets of yours, so the guest reaches your LAN, and every non-loopback address of this machine: services listening on `0.0.0.0`, Docker's bridge, a VPN's or Tailscale's address. Since that traffic is local, a firewall that keeps the LAN out of those services usually lets it through. On a cloud host that includes the metadata service at `169.254.169.254`. Builds need the network for packages, so this is the residual risk: a build step that misbehaved could reach them.
- **QEMU and passt run as you.** passt sandboxes itself; QEMU runs under its own seccomp filter (`-sandbox on`, no new privileges, no spawning, no obsolete syscalls). An escape from the VM would still be code running as your user.
- **SSH into the guest is pinned.** Every `setup` makes a new host key on your side and hands it over in the seed, which is deleted once first boot has used it, so the first connection is already checked. A dedicated client key is the only one ever offered, and nothing prompts.
- **No shared directory, socket or device.** Nothing is mounted into the guest, and the only port forward is SSH, on `127.0.0.1`.
- **What the guest prints through `vm.sh` is cleaned** of terminal control sequences before it reaches your terminal, and no terminal input reaches the guest. Two things are raw: a `vm.sh ssh` session, and `run/console.log`, the guest's serial console (kept to its first 64M). Read the log with `less`, which shows control characters rather than sending them to the terminal, not with `cat`.

## The base image

The VM is Arch Linux's official x86_64 cloud image from `arch-boxes`. `manifest.toml` `[build-vm]` pins the release, its sha256 and the fingerprint of the key that signs it. `fetch-base` refuses anything that does not match all three, or whose signature is bad, expired or revoked. The key block itself is in `scripts/vm/arch-boxes.asc`, so the check trusts nothing it downloads alongside the image.

That key's only published home is the `arch-boxes` README on gitlab.archlinux.org: it is self-signed, and on 2026-10-19 it was not in the pacman keyring, on keys.openpgp.org or in Arch's WKD. Its signing subkey expires on 2027-05-28; after that, refresh `arch-boxes.asc` from the README and check its fingerprint against `signing-key` before moving the pin. To move to a newer release, take the new version's `.SHA256`, check its `.sig` against `arch-boxes.asc`, and change `version` and `sha256` together.
