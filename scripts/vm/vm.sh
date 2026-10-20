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
#   vm.sh build <ref> [key]  a fresh VM, <ref> built and checked in it, the
#                            images out, the VM off. With an ssh public key the
#                            dev image is keyed to it and copied out too.
#                            VM_REUSE=1 builds in the running VM instead.
#   vm.sh ssh [cmd...]       a shell in the guest
#   vm.sh stop               power it off
#   vm.sh destroy            stop it and delete its disk (the base stays)
#
# State lives in $MOARCHY_VM_DIR (default ~/.local/share/moarchy-build-vm),
# never in the repo. VM_CPUS, VM_MEM, VM_DISK, VM_PORT and VM_DNS override the
# defaults below.
set -euo pipefail
# The guest's host private key passes through files here; nothing this makes
# is anyone else's to read.
umask 077
REPO=$(cd "$(dirname "$0")/../.." && pwd)
VM=$REPO/scripts/vm
D=${MOARCHY_VM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/moarchy-build-vm}
. "$REPO/scripts/manifest.sh"

# At most 16, and QEMU at nice 10 (start below): every thread of the host held
# the desktop at a load of 88 for the length of a build. A build takes a little
# longer; the machine stays usable.
CPUS=${VM_CPUS:-$(( $(nproc) < 16 ? $(nproc) : 16 ))}
# 12G: the largest build container measured so far peaked at 2.4G. The balloon
# hands pages the guest frees back to the host instead of holding them.
MEM=${VM_MEM:-12G}
DISK=${VM_DISK:-150G}
PORT=${VM_PORT:-2222}
# The host may resolve through a stub on 127.0.0.53, which the guest cannot
# reach with the host's loopback unmapped, so it is given servers directly.
DNS=${VM_DNS:-1.1.1.1 1.0.0.1}

OVL=$D/run/overlay.qcow2
# A unix socket path holds 107 bytes, which a state directory deep in $HOME can
# outgrow; the runtime directory is short, and the user's alone. Named for the
# port, which two VMs cannot share either.
SOCK=${XDG_RUNTIME_DIR:-$D/run}/moarchy-build-vm-$PORT.passt

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
# The guest's stderr cleaned too: a guest-written ~/.bashrc, or a replaced
# tail, can print to either.
gssh() { ssh "${ssh_opts[@]}" builder@127.0.0.1 "$@" 2> >(clean >&2); }

# The pid a pidfile names, only while it is still that program: pidfiles here
# outlive a host reboot or a killed QEMU, and the number may since have gone to
# some other process of yours.
pid_of() {
  local pid; pid=$(cat "$1" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && [[ $(cat "/proc/$pid/comm" 2>/dev/null) == "$2"* ]] && echo "$pid"
}
running() { pid_of "$D/run/qemu.pid" qemu-system >/dev/null; }
kill_passt() {
  local pid; pid=$(pid_of "$D/run/passt.pid" passt) && kill "$pid" 2>/dev/null
  rm -f "$D/run/passt.pid" "$SOCK"
}

# One EXIT trap for everything a run sets up, each step adding its own cleanup.
# The values are captured as they are added: the variables are local, and gone
# by the time the script exits.
# set +e first: a step that fails must not skip the ones after it.
CLEANUP='set +e'
on_exit() { CLEANUP="$CLEANUP; $1"; trap "$CLEANUP" EXIT; }
# A value as it is now, quoted for the trap, whatever characters it holds.
q() { printf '%q' "$1"; }
# bash runs no EXIT trap when a signal ends it, which left a VM, its passt and
# the isolation listener running after a Ctrl-C. Ended by one, it exits, and
# cleans up. Ctrl-C during a build therefore stops the VM too.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# What the guest prints, with the terminal's control sequences taken out: a
# build log carries upstream builds' output, and an escape sequence in it
# should not reach your terminal (titles, clipboard, hyperlinks).
# Bytes, not characters: in a UTF-8 locale sed rejects the byte range below.
clean() { LC_ALL=C sed -u 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b[]P^_][^\x07\x1b]*\(\x07\|\x1b\\\)//g; s/[\x00-\x08\x0b-\x1f\x7f]//g; s/\xc2[\x80-\x9f]//g'; }

fetch_base() {
  local version sha key url f tmp g st
  version=$(manifest_get build-vm version) || exit 1
  sha=$(manifest_get build-vm sha256) || exit 1
  key=$(manifest_get build-vm signing-key) || exit 1
  url="$(manifest_get build-vm base-url)/v$version" || exit 1
  f=Arch-Linux-x86_64-cloudimg-$version.qcow2
  [ -f "$D/base/$f" ] && { echo "already fetched: $D/base/$f"; return; }
  mkdir -p "$D/base"
  tmp=$(mktemp -d "$D/base/.fetch.XXXXXX")
  on_exit "rm -rf $(q "$tmp")"
  curl -fL --progress-bar --proto '=https' --max-filesize 4G --max-time 3600 -o "$tmp/$f" "$url/$f"
  curl -fsSL --proto '=https' --max-filesize 64K --max-time 60 -o "$tmp/$f.sig" "$url/$f.sig"
  echo "$sha  $tmp/$f" | sha256sum -c --quiet - || die "$f does not match the pinned sha256"
  # The key from the repo, in a keyring of its own. A good, unexpired,
  # unrevoked signature, by exactly the pinned key: VALIDSIG's last field is
  # the primary key's fingerprint, whichever subkey signed. The sha256 above
  # is the pin; this is the second, independent check on it.
  g=$tmp/gnupg; mkdir -m 700 "$g"
  gpg --homedir "$g" --batch --quiet --import "$VM/arch-boxes.asc" 2>/dev/null
  st=$(gpg --homedir "$g" --batch --status-fd 1 --verify "$tmp/$f.sig" "$tmp/$f" 2>/dev/null) ||
    die "$f: the signature does not verify"
  grep -qE '^\[GNUPG:\] (EXPSIG|EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG)' <<<"$st" &&
    die "$f: the signature is expired, revoked or bad"
  grep -q '^\[GNUPG:\] GOODSIG' <<<"$st" || die "$f: no good signature"
  [ "$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$st")" = "$key" ] ||
    die "$f is not signed by arch-boxes' key $key"
  chmod 444 "$tmp/$f"
  mv "$tmp/$f" "$D/base/$f"
  echo "fetched $D/base/$f: sha256 and arch-boxes signature good"
}

setup() {
  local base; base=$(base_image)
  [ -f "$base" ] || die "no base image; run: $0 fetch-base"
  running && die "the VM is running; stop it first"
  umask 077
  mkdir -p "$D/keys" "$D/run" "$D/seed" "$D/out"
  chmod 700 "$D"
  [ -f "$D/keys/client_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C moarchy-build-client -f "$D/keys/client_ed25519"
  # A host key of its own for every VM, made here and handed to it, so the
  # first connection is already pinned and a key one guest had is no use
  # against the next.
  rm -f "$D/keys/host_ed25519" "$D/keys/host_ed25519.pub"
  ssh-keygen -q -t ed25519 -N '' -C moarchy-build-vm -f "$D/keys/host_ed25519"
  echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/keys/host_ed25519.pub")" > "$D/keys/known_hosts"
  sed -e "s|@CLIENT_PUB@|$(cat "$D/keys/client_ed25519.pub")|" \
      -e "s|@HOST_PUB@|$(cat "$D/keys/host_ed25519.pub")|" \
      -e '/@HOST_PRIV@/{
            r '"$D/keys/host_ed25519"'
            d
          }' "$VM/user-data.in" > "$D/seed/user-data"
  sed -i '/BEGIN OPENSSH PRIVATE KEY/,/END OPENSSH PRIVATE KEY/s/^/      /' "$D/seed/user-data"
  printf 'instance-id: moarchy-build-%s\nlocal-hostname: moarchy-build\n' "$(date +%s)" > "$D/seed/meta-data"
  xorriso -as mkisofs -quiet -o "$D/run/seed.iso" -V cidata -J -R "$D/seed/user-data" "$D/seed/meta-data"
  rm -f "$OVL"
  qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$OVL" "$DISK"
  echo "setup done: a fresh disk over $(basename "$base"), a new pinned host key"
}

start() {
  [ -f "$OVL" ] || die "no VM disk; run: $0 setup"
  running && die "already running"
  (( ${#SOCK} <= 107 )) || die "the passt socket path is longer than a unix socket allows: $SOCK"
  rm -f "$SOCK" "$D/run/qemu.pid"
  local dns=() d seed=()
  for d in $DNS; do dns+=(-D "$d"); done
  # The seed only until first boot has used it (wait_ready deletes it): it
  # holds the guest's host private key.
  [ -f "$D/run/seed.iso" ] && seed=(-drive file="$D/run/seed.iso",if=virtio,format=raw,readonly=on)
  # --map-host-loopback none: packets the guest sends to the host's loopback
  # are dropped, not delivered (passt(1)), so nothing listening on 127.0.0.1
  # or ::1 here is reachable from in there. check-isolation tests it. A fixed
  # guest address, because passt otherwise copies the host's, which a VPN's
  # interface can make equal to the gateway's.
  passt -1 -s "$SOCK" -P "$D/run/passt.pid" -t "127.0.0.1/$PORT:22" -u none \
    -a 10.0.2.15 -n 24 -g 10.0.2.2 "${dns[@]}" \
    --map-host-loopback none --map-guest-addr none
  # A passt left waiting for a QEMU that never came would hold the port.
  on_exit "running || kill_passt"
  # QEMU under its own seccomp filter: no new privileges, no spawning, none of
  # the obsolete syscalls. Started in the background from here rather than with
  # -daemonize, which the filter's spawn=deny rules out.
  setsid -f nice -n 10 qemu-system-x86_64 -enable-kvm -cpu host -smp "$CPUS" -m "$MEM" -nographic \
    -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
    -device virtio-balloon-pci,free-page-reporting=on \
    -drive file="$OVL",if=virtio,format=qcow2 "${seed[@]}" \
    -netdev stream,id=n0,server=off,addr.type=unix,addr.path="$SOCK" \
    -device virtio-net-pci,netdev=n0 \
    -nodefaults -serial file:"$D/run/console.log" -display none \
    -pidfile "$D/run/qemu.pid" </dev/null >>"$D/run/qemu.log" 2>&1
  for _ in $(seq 20); do running && break; sleep 0.5; done
  running || die "QEMU did not start; see $D/run/qemu.log"
  echo "started; console: $D/run/console.log"
}

# First boot installs Docker and qemu-user, writes the marker, then reboots
# once: ready is the marker from an earlier boot than this one, and Docker up.
wait_ready() {
  local i
  for i in $(seq 200); do
    if gssh 'm=$(cat /var/lib/moarchy-build-ready 2>/dev/null) && [ -n "$m" ] &&
          [ "$m" != "$(cat /proc/sys/kernel/random/boot_id)" ] && systemctl is-active -q docker' 2>/dev/null; then
      rm -f "$D/run/seed.iso" "$D/seed/user-data"
      echo "ready"
      return
    fi
    running || die "the VM stopped; see $D/run/console.log"
    sleep 6
  done
  die "not ready after 20 minutes; see $D/run/console.log"
}

# Listeners on the host's loopback, IPv4 and IPv6, and the guest trying the
# addresses that could lead to them: its IPv4 gateway, and its IPv6 one if it
# has one. The verdict is the host's, not the guest's: a listener that logs
# any connection at all fails the check, whatever the guest says. The guest's
# own outbound HTTPS must work, or the check proves nothing but a dead network.
check_isolation() {
  local port token pid log out
  port=$(( 20000 + RANDOM % 20000 ))
  token=moarchy-isolation-$RANDOM$RANDOM
  log=$(mktemp "$D/run/isolation.XXXXXX")
  python3 -I -c '
import http.server, socket, sys, threading
port, token, log = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    # Any connection at all, logged before a byte of it is read.
    def setup(self):
        with open(log, "a") as f: f.write(f"{self.client_address[0]}\n")
        super().setup()
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(token)
    def log_message(self, *a): pass
class S6(http.server.HTTPServer): address_family = socket.AF_INET6
servers = [http.server.HTTPServer(("127.0.0.1", port), H), S6(("::1", port), H)]
for s in servers: threading.Thread(target=s.serve_forever, daemon=True).start()
threading.Event().wait()
' "$port" "$token" "$log" & pid=$!
  on_exit "kill $pid 2>/dev/null; rm -f $(q "$log")"
  sleep 1
  curl -fsS "http://127.0.0.1:$port/" | grep -q "$token" && curl -fsS -g "http://[::1]:$port/" | grep -q "$token" ||
    die "the test listeners did not come up"
  : >"$log"
  # curl's own exit code beside each, so a refused or timed-out connection (7,
  # 28) can be told from a URL that was never usable (3), which proves nothing.
  out=$(gssh "set -- \$(ip -6 route show default 2>/dev/null | head -1)
    gw6=\${3:-} dev6=\${5:-}
    for a in 10.0.2.2 \${gw6:+[\$gw6%\$dev6]}; do
      curl -fsS -g --max-time 4 -o /dev/null http://\$a:$port/ 2>/dev/null; echo \"guest probe \$a: curl exit \$?\"
    done
    curl -fsS --max-time 15 -o /dev/null -w 'outbound https %{http_code}\n' https://archlinux.org/" | clean || true)
  echo "$out"
  [ -s "$log" ] && die "the host's loopback listener was reached from the guest ($(tr '\n' ' ' <"$log"))"
  grep -q 'outbound https 200' <<<"$out" || die "the guest has no working network; the check above proves nothing"
  grep -E '^guest probe .*: curl exit (3|6)$' <<<"$out" && die "a probe's URL was unusable; the check above proves nothing"
  if grep -q '^guest probe \[' <<<"$out"; then
    echo "isolated: the host's loopback, IPv4 and IPv6, saw nothing from the guest"
  else
    echo "isolated: the host's loopback saw nothing from the guest (it has no IPv6 route to probe)"
  fi
}

# Copy one expected file out, by name, as bytes: whatever the guest put at that
# path, a symlink, a pipe or a device, only its contents arrive, as a regular
# file of at most $3 bytes.
fetch_file() {
  gssh "cat ~/out/$1" | head -c "$3" >"$2" || true
}

# The three images and their SHA256SUMS, and nothing else: SHA256SUMS must
# name exactly those three, so it can make sha256sum open no other path.
check_sums() {
  local dir=$1
  [ "$(awk '{print $2}' "$dir/SHA256SUMS" | sort | tr '\n' ' ')" = "boot.img rootfs.simg vbmeta.img " ] &&
    ! grep -qvE '^[0-9a-f]{64}  (boot\.img|vbmeta\.img|rootfs\.simg)$' "$dir/SHA256SUMS" ||
    die "$dir/SHA256SUMS does not list exactly boot.img, vbmeta.img and rootfs.simg"
  (cd "$dir" && sha256sum -c --quiet SHA256SUMS) || die "$dir did not arrive intact"
}

build() {
  local ref=${1:?usage: $0 build <ref> [ssh-public-key]} key=${2:-} sha bundle out sub
  sha=$(git -C "$REPO" rev-parse --verify "$ref^{commit}") || die "no such ref: $ref"
  if [ -n "$key" ]; then
    grep -qi 'PRIVATE KEY' "$key" && die "$key is a private key; give the .pub"
    ssh-keygen -l -f "$key" >/dev/null || die "$key is not an ssh public key"
  fi
  # A fresh VM for every build, so nothing one build did can reach the next:
  # not its kernel cache, not a compromised guest, not a guest reporting the
  # next build's result. VM_REUSE=1 builds in the running VM instead, for when
  # every ref built in it since its last setup is one you trust.
  # One build at a time here: a second one would power off and delete the
  # first one's VM.
  mkdir -p "$D/run"
  exec 8>"$D/run/build.lock"
  flock -n 8 || die "another vm.sh build is using $D"
  if [ "${VM_REUSE:-0}" = 1 ]; then
    running || die "VM_REUSE=1, but the VM is not running"
    gssh '[ -f ~/build.pid ] && kill -0 "$(cat ~/build.pid)" 2>/dev/null' &&
      die "a build is still running in the VM; wait for it, or stop the VM"
  else
    running && die "a VM is running; stop it first, or build in it with VM_REUSE=1"
    setup
    start
    on_exit "$(q "$0") stop >/dev/null 2>&1"
    wait_ready
    check_isolation
  fi
  bundle=$(mktemp "$D/run/bundle.XXXXXX")
  # One ref, in a namespace of its own so no branch of yours is touched, and
  # gone again as soon as the bundle is written. A bundle carries the history
  # behind it too, unpushed commits included.
  on_exit "rm -f $(q "$bundle"); git -C $(q "$REPO") update-ref -d refs/moarchy-vm/build 2>/dev/null"
  git -C "$REPO" update-ref refs/moarchy-vm/build "$sha"
  git -C "$REPO" bundle create -q "$bundle" refs/moarchy-vm/build
  git -C "$REPO" update-ref -d refs/moarchy-vm/build
  # The last build's log, result and images gone too, or a ref that never got
  # as far as starting its log would be judged on the previous one's.
  gssh 'rm -rf ~/in ~/out ~/build.log ~/build.pid && mkdir -p ~/in'
  gssh 'cat > ~/in/moarchy.bundle' <"$bundle"
  # The ref's own build script, not this checkout's: a ref is built the way it
  # says it is built.
  git -C "$REPO" show "$sha:scripts/vm/in-vm-build.sh" >/dev/null 2>&1 ||
    die "$ref has no scripts/vm/in-vm-build.sh; it predates the build VM"
  git -C "$REPO" show "$sha:scripts/vm/in-vm-build.sh" | gssh 'cat > ~/in-vm-build.sh && chmod +x ~/in-vm-build.sh'
  if [ -n "$key" ]; then gssh 'cat > ~/in/dev.pub' <"$key"; fi
  # Detached in the guest, so a dropped connection does not end the build. The
  # log is followed until the build has exited, and followed again if the
  # connection drops first: the verdict is only read once there is one.
  gssh 'setsid nohup ~/in-vm-build.sh refs/moarchy-vm/build >/dev/null 2>&1 </dev/null & echo $! > ~/build.pid'
  # Nothing the guest prints here is evaluated: the line count is taken only
  # if it is a number, and a failed connection is a retry, not an exit.
  local from=1 state n
  while :; do
    state=$(gssh 'kill -0 "$(cat ~/build.pid)" 2>/dev/null && echo running || echo done' || true)
    [ "$state" = done ] && break
    if [ "$state" = running ]; then
      gssh "sleep 2; tail -n +$from --pid=\"\$(cat ~/build.pid)\" -f ~/build.log" | clean || true
    else
      running || die "the VM stopped during the build; see $D/run/console.log"
      sleep 5
    fi
    n=$(gssh 'wc -l < ~/build.log' || true)
    [[ $n =~ ^[0-9]+$ ]] && from=$(( n + 1 ))
  done
  gssh "tail -n +$from ~/build.log" | clean || true
  gssh 'tail -n 1 ~/build.log' | grep -q 'BUILD OK' || die "the build failed; the log is above, and in the guest at ~/build.log"
  out=$(mktemp -d "$D/out/$(git -C "$REPO" rev-parse --short "$sha")-$(date +%Y%m%d-%H%M).XXXX")
  # The dev image only when it is yours: without a key, the guest's throwaway
  # one built and checked it, as CI's does, and it stays in there.
  for sub in release ${key:+dev}; do
    mkdir "$out/$sub"
    fetch_file "$sub/boot.img"    "$out/$sub/boot.img"    $((256 << 20))
    fetch_file "$sub/vbmeta.img"  "$out/$sub/vbmeta.img"  $((1 << 20))
    fetch_file "$sub/rootfs.simg" "$out/$sub/rootfs.simg" $((16 << 30))
    fetch_file "$sub/SHA256SUMS"  "$out/$sub/SHA256SUMS"  4096
    check_sums "$out/$sub"
  done
  if [ "${VM_REUSE:-0}" != 1 ]; then stop; fi
  echo "images: $out"
  ls -d "$out"/*/
}

stop() {
  local pid
  if pid=$(pid_of "$D/run/qemu.pid" qemu-system); then
    # The connection drops as the guest shuts down, so ssh's exit status says
    # nothing; only a guest still running after the wait is killed.
    gssh 'sync; sudo systemctl poweroff' 2>/dev/null || true
    for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill "$pid" 2>/dev/null || true
  fi
  kill_passt || true
  rm -f "$D/run/qemu.pid"
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
  destroy) stop; rm -f "$OVL" "$D/run/seed.iso" "$D/seed/user-data"; echo "disk deleted" ;;
  *) sed -n '11,26p' "$0"; exit 1 ;;
esac
