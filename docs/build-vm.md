# The build VM

Building and checking an image means running privileged containers: `arch-chroot` mounts, loop devices, the negative test's planted defects. `scripts/vm/vm.sh` runs them inside a throwaway KVM virtual machine instead of on your machine, the same steps in the same order as CI (`.github/workflows/image.yml`). A git bundle of one commit goes in, and so does a public key if you want a dev image. What comes out is the images.

CI already does all of this on a fresh GitHub runner for every pull request. The VM is for building and flashing locally without giving a build root on your own machine.

## What you need

An x86_64 Linux machine with KVM, and `qemu-system-x86_64`, `qemu-img`, `passt`, `xorriso`, `gpg`, `curl`, `git` and `python3`. About 30 GB free for the disk the VM grows into (it is sparse, capped at 150 GB), and 12 GB of memory while it runs. Nothing runs as root on the host: no libvirt, no sudo, no Docker.

## Use

```sh
scripts/vm/vm.sh fetch-base        # the pinned Arch cloud image, checked
scripts/vm/vm.sh setup             # keys, cloud-init seed, a fresh disk
scripts/vm/vm.sh start
scripts/vm/vm.sh wait              # first boot installs Docker and qemu-user, then reboots
scripts/vm/vm.sh check-isolation   # prove the guest cannot reach your loopback
scripts/vm/vm.sh build HEAD ~/.ssh/id_ed25519.pub
scripts/vm/vm.sh stop
```

`build` takes any commit of this repo, and builds the release image and, given a public key, a dev image that admits that key over the USB cable (`docs/structure.md` I5). It prints the build as it goes and fails on anything CI would fail on, with one exception: verify.sh's online-resize check needs a native arm64 kernel, so under the VM's emulation that one FAIL is allowed, and CI checks it.

The images land in `~/.local/share/moarchy-build-vm/out/<commit>-<time>/{release,dev}`. Flash one with `scripts/vm/flash-sargo.sh <directory>`, the script from this repo, never the `flash.sh` a build writes into its own output: anything that comes out of the VM is data to check, not a program to run. The checksums it checks prove the files arrived as the VM wrote them, and nothing more.

Everything the VM keeps (its base image, keys, disk and output) is under `$MOARCHY_VM_DIR`, by default `~/.local/share/moarchy-build-vm`, and never in the repo. `VM_CPUS`, `VM_MEM`, `VM_DISK`, `VM_PORT` and `VM_DNS` override the defaults at the top of `vm.sh`. `vm.sh destroy` deletes the disk; the next `setup` starts from the clean base image again.

## What the isolation is, and is not

- **The host's loopback is unreachable.** passt runs with `--map-host-loopback none`, under which packets the guest sends to the host's loopback are dropped (passt(1)). `check-isolation` tests that on your machine, rather than leaving it to this sentence. It puts a listener on `127.0.0.1` and has the guest try every address that could lead to it, and it checks the guest's own HTTPS works, so a dead network cannot pass for isolation.
- **The guest reaches the network**, including your LAN. Builds download packages, so this is the residual risk: a build step that misbehaved could talk to other machines on your network.
- **SSH into the guest is pinned.** `setup` makes the guest's host key on your side and hands it over, so the first connection is already checked. A dedicated client key is the only one ever offered, and nothing prompts.
- **No shared directory, socket or device.** Nothing is mounted into the guest. QEMU and passt run as you.

## The base image

The VM is Arch Linux's official x86_64 cloud image from `arch-boxes`. `manifest.toml` `[build-vm]` pins the release, its sha256 and the fingerprint of the key that signs it. `fetch-base` refuses anything that does not match all three. The key block itself is in `scripts/vm/arch-boxes.asc`, so the check trusts nothing it downloads alongside the image.

That key's only published home is the `arch-boxes` README on gitlab.archlinux.org: it is self-signed, and on 2026-10-19 it was not in the pacman keyring, on keys.openpgp.org or in Arch's WKD. To move to a newer release, take the new version's `.SHA256`, check its `.sig` against `arch-boxes.asc`, and change `version` and `sha256` together.
