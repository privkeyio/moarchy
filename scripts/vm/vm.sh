#!/bin/bash
# A throwaway KVM VM that builds and checks moarchy images (docs/build-vm.md).
#
# Building an image runs privileged containers (arch-chroot, loop devices). In
# here they reach the VM and nothing else: the host runs QEMU and passt as the
# invoking user, with no libvirt, no sudo, no Docker socket, no shared
# directory and no USB passthrough, and the host's loopback is not mapped into
# the guest. What goes in is a git bundle of one ref and, for a dev image, a
# public key; what comes out is the images.
#
#   vm.sh fetch-base         the pinned Arch cloud image, sha256 and signature checked
#   vm.sh setup              keys, cloud-init seed, a fresh disk over the base
#   vm.sh start              boot it, isolated
#   vm.sh wait               until first-boot provisioning is done
#   vm.sh check-isolation    prove the guest cannot reach the host's loopback
#   vm.sh build <ref> [key]  build <ref> of this repo; with an ssh public key,
#                            a dev image too. Images land in $VM_DIR/out/
#   vm.sh ssh [cmd...]       a shell in the guest
#   vm.sh stop               power it off
#   vm.sh destroy            stop it and delete its disk (the base stays)
#
# State lives in $MOARCHY_VM_DIR (default ~/.local/share/moarchy-build-vm),
# never in the repo. VM_CPUS, VM_MEM, VM_DISK, VM_PORT and VM_DNS override the
# defaults below.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
VM=$REPO/scripts/vm
D=${MOARCHY_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/moarchy-build-vm}
. "$REPO/scripts/manifest.sh"

CPUS=${VM_CPUS:-$(nproc)}
# 12G: the largest build container measured so far peaked at 2.4G. The balloon
# hands pages the guest frees back to the host instead of holding them.
MEM=${VM_MEM:-12G}
DISK=${VM_DISK:-150G}
PORT=${VM_PORT:-2222}
# The host may resolve through a stub on 127.0.0.53, which the guest cannot
# reach with the host's loopback unmapped, so it is given servers directly.
DNS=${VM_DNS:-1.1.1.1 1.0.0.1}

OVL=$D/run/overlay.qcow2
SOCK=$D/run/passt.socket

die() { echo "${0##*/}: $*" >&2; exit 1; }

base_image() {
  echo "$D/base/Arch-Linux-x86_64-cloudimg-$(manifest_get build-vm version).qcow2"
}

# -F /dev/null and BatchMode: only the dedicated key is ever offered, never one
# from ~/.ssh/config, the host key is the one setup generated, and nothing
# prompts while the guest is still booting.
ssh_opts=(-F /dev/null -o BatchMode=yes
          -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$D/keys/known_hosts"
          -o HostKeyAlgorithms=ssh-ed25519
          -o IdentitiesOnly=yes -o IdentityFile="$D/keys/client_ed25519"
          -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$PORT")
gssh() { ssh "${ssh_opts[@]}" builder@127.0.0.1 "$@"; }

running() { [ -f "$D/run/qemu.pid" ] && kill -0 "$(cat "$D/run/qemu.pid")" 2>/dev/null; }

fetch_base() {
  local version sha key url f tmp g fpr
  version=$(manifest_get build-vm version) || exit 1
  sha=$(manifest_get build-vm sha256) || exit 1
  key=$(manifest_get build-vm signing-key) || exit 1
  url="$(manifest_get build-vm base-url)/v$version" || exit 1
  f=Arch-Linux-x86_64-cloudimg-$version.qcow2
  [ -f "$D/base/$f" ] && { echo "already fetched: $D/base/$f"; return; }
  mkdir -p "$D/base"
  tmp=$(mktemp -d "$D/base/.fetch.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  curl -fL --proto '=https' -o "$tmp/$f" "$url/$f"
  curl -fsSL --proto '=https' -o "$tmp/$f.sig" "$url/$f.sig"
  echo "$sha  $tmp/$f" | sha256sum -c --quiet - || die "$f does not match the pinned sha256"
  # The key from the repo, in a keyring of its own, and the signature must be
  # by exactly the pinned key: gpg's VALIDSIG names the primary fingerprint.
  g=$tmp/gnupg; mkdir -m 700 "$g"
  gpg --homedir "$g" --batch --quiet --import "$VM/arch-boxes.asc" 2>/dev/null
  fpr=$(gpg --homedir "$g" --batch --status-fd 1 --verify "$tmp/$f.sig" "$tmp/$f" 2>/dev/null |
        awk '$2 == "VALIDSIG" { print $NF }')
  [ "$fpr" = "$key" ] || die "$f is not signed by arch-boxes' key $key${fpr:+ (signed by $fpr)}"
  chmod 444 "$tmp/$f"
  mv "$tmp/$f" "$D/base/$f"
  echo "fetched $D/base/$f: sha256 and arch-boxes signature good"
}

setup() {
  local base; base=$(base_image)
  [ -f "$base" ] || die "no base image; run: $0 fetch-base"
  running && die "the VM is running; stop it first"
  mkdir -p "$D/keys" "$D/run" "$D/seed" "$D/out"
  [ -f "$D/keys/client_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C moarchy-build-client -f "$D/keys/client_ed25519"
  [ -f "$D/keys/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C moarchy-build-vm -f "$D/keys/host_ed25519"
  # The guest's host key is made here and handed to it, so the first
  # connection is already pinned: nothing is ever accepted on first use.
  echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/keys/host_ed25519.pub")" > "$D/keys/known_hosts"
  sed -e "s|@CLIENT_PUB@|$(cat "$D/keys/client_ed25519.pub")|" \
      -e "s|@HOST_PUB@|$(cat "$D/keys/host_ed25519.pub")|" \
      -e '/@HOST_PRIV@/{
            r '"$D/keys/host_ed25519"'
            d
          }' "$VM/user-data.in" > "$D/seed/user-data"
  sed -i '/BEGIN OPENSSH PRIVATE KEY/,/END OPENSSH PRIVATE KEY/s/^/      /' "$D/seed/user-data"
  chmod 600 "$D/seed/user-data"
  printf 'instance-id: moarchy-build-%s\nlocal-hostname: moarchy-build\n' "$(date +%s)" > "$D/seed/meta-data"
  xorriso -as mkisofs -quiet -o "$D/run/seed.iso" -V cidata -J -R "$D/seed/user-data" "$D/seed/meta-data"
  rm -f "$OVL"
  qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$OVL" "$DISK"
  echo "setup done: a fresh disk over $(basename "$base"), pinned host key"
}

start() {
  [ -f "$OVL" ] || die "no VM disk; run: $0 setup"
  running && die "already running"
  rm -f "$SOCK"
  local dns=() d
  for d in $DNS; do dns+=(-D "$d"); done
  # --map-host-loopback none: packets the guest sends to the host's loopback
  # are dropped, not delivered (passt(1)), so nothing listening on 127.0.0.1
  # here is reachable from in there. check-isolation tests it. A fixed guest
  # address, because passt otherwise copies the host's, which a VPN's
  # interface can make equal to the gateway's.
  passt -1 -s "$SOCK" -P "$D/run/passt.pid" -t "127.0.0.1/$PORT:22" -u none \
    -a 10.0.2.15 -n 24 -g 10.0.2.2 "${dns[@]}" \
    --map-host-loopback none --map-guest-addr none
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$CPUS" -m "$MEM" -nographic \
    -device virtio-balloon-pci,free-page-reporting=on \
    -drive file="$OVL",if=virtio,format=qcow2 \
    -drive file="$D/run/seed.iso",if=virtio,format=raw,readonly=on \
    -netdev stream,id=n0,server=off,addr.type=unix,addr.path="$SOCK" \
    -device virtio-net-pci,netdev=n0 \
    -nodefaults -serial file:"$D/run/console.log" -display none \
    -pidfile "$D/run/qemu.pid" -daemonize
  echo "started; console: $D/run/console.log"
}

# First boot installs Docker and qemu-user, then reboots once.
wait_ready() {
  local i
  for i in $(seq 200); do
    gssh test -e /var/lib/moarchy-build-ready 2>/dev/null && { echo "ready"; return; }
    running || die "the VM stopped; see $D/run/console.log"
    sleep 6
  done
  die "not ready after 20 minutes; see $D/run/console.log"
}

# A listener on the host's loopback, and the guest trying every address that
# could lead to it. Any answer fails the check. The guest's own outbound HTTPS
# must work, or the check proves nothing but a dead network.
check_isolation() {
  local port token pid out
  port=$(( 20000 + RANDOM % 20000 ))
  token=moarchy-isolation-$RANDOM$RANDOM
  python3 -I -c '
import http.server, sys
port, token = int(sys.argv[1]), sys.argv[2].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(token)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
' "$port" "$token" & pid=$!
  trap 'kill "$pid" 2>/dev/null' EXIT
  sleep 1
  curl -fsS "http://127.0.0.1:$port/" | grep -q "$token" || die "the test listener did not come up"
  out=$(gssh "for a in 10.0.2.2 10.0.2.15 127.0.0.1; do
    if curl -fsS --max-time 4 http://\$a:$port/ 2>/dev/null | grep -q $token; then echo \"REACHED \$a\"; else echo \"blocked \$a\"; fi
  done; curl -fsS --max-time 15 -o /dev/null -w 'outbound https %{http_code}\n' https://archlinux.org/")
  echo "$out"
  grep -q REACHED <<<"$out" && die "the guest reached the host's loopback"
  grep -q 'outbound https 200' <<<"$out" || die "the guest has no working network; the check above proves nothing"
  echo "isolated: the host's loopback is unreachable from the guest"
}

build() {
  local ref=${1:?usage: $0 build <ref> [ssh-public-key]} key=${2:-} sha bundle out
  running || die "the VM is not running; run: $0 start"
  sha=$(git -C "$REPO" rev-parse --verify "$ref^{commit}") || die "no such ref: $ref"
  if [ -n "$key" ]; then
    grep -qi 'PRIVATE KEY' "$key" && die "$key is a private key; give the .pub"
    ssh-keygen -l -f "$key" >/dev/null || die "$key is not an ssh public key"
  fi
  bundle=$(mktemp "$D/run/bundle.XXXXXX")
  # One ref, in a namespace of its own so no branch of yours is touched, and
  # gone again as soon as the bundle is written.
  trap 'rm -f "$bundle"; git -C "$REPO" update-ref -d refs/moarchy-vm/build 2>/dev/null' EXIT
  git -C "$REPO" update-ref refs/moarchy-vm/build "$sha"
  git -C "$REPO" bundle create -q "$bundle" refs/moarchy-vm/build
  git -C "$REPO" update-ref -d refs/moarchy-vm/build
  gssh 'rm -rf ~/in && mkdir -p ~/in'
  gssh 'cat > ~/in/moarchy.bundle' <"$bundle"
  gssh 'cat > ~/in-vm-build.sh && chmod +x ~/in-vm-build.sh' <"$VM/in-vm-build.sh"
  [ -n "$key" ] && gssh 'cat > ~/in/dev.pub' <"$key"
  # Detached in the guest, so a dropped connection does not end the build; the
  # log is followed until the build exits.
  gssh 'setsid nohup ~/in-vm-build.sh refs/moarchy-vm/build >/dev/null 2>&1 </dev/null & echo $! > ~/build.pid'
  gssh 'sleep 2; tail -n +1 --pid="$(cat ~/build.pid)" -f ~/build.log' || true
  gssh 'tail -n 1 ~/build.log' | grep -q 'BUILD OK' || die "the build failed; the log is above, and in the guest at ~/build.log"
  out=$D/out/$(git -C "$REPO" rev-parse --short "$sha")-$(date +%Y%m%d-%H%M)
  mkdir -p "$out"
  gssh 'tar -C ~/out -cf - .' | tar -C "$out" -xf -
  local d
  for d in "$out"/*/; do (cd "$d" && sha256sum -c --quiet SHA256SUMS) || die "$d did not arrive intact"; done
  echo "images: $out"
  ls -d "$out"/*/
}

stop() {
  if running; then
    local pid; pid=$(cat "$D/run/qemu.pid")
    # The connection drops as the guest shuts down, so ssh's exit status says
    # nothing; only a guest still running after the wait is killed.
    gssh 'sync; sudo systemctl poweroff' 2>/dev/null || true
    for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$D/run/qemu.pid" "$D/run/passt.pid" "$SOCK"
}

case "${1:-}" in
  fetch-base) fetch_base ;;
  setup) setup ;;
  start) start ;;
  wait) wait_ready ;;
  check-isolation) check_isolation ;;
  build) shift; build "$@" ;;
  ssh) shift; exec ssh "${ssh_opts[@]}" builder@127.0.0.1 "$@" ;;
  stop) stop ;;
  destroy) stop; rm -f "$OVL" "$D/run/seed.iso"; echo "disk deleted" ;;
  *) sed -n '11,24p' "$0"; exit 1 ;;
esac
