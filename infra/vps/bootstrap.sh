#!/usr/bin/env bash
# Prepares a fresh Ubuntu 24.04 server for the CarmaCars Supabase stack and installs (or updates) its files.
# Run as root from the unpacked infra/vps folder (the vps-provision workflow does this over SSH). Idempotent: every
# step checks first, so running it again only applies what changed. It does not start the stack (bin/stack-up does,
# once make-env.sh has written /opt/carmacars/supabase/.env).
#
#   1. UTC clock, packages, unattended security upgrades (no automatic reboot: the database runs here)
#   2. SSH: keys only, no root login, no passwords; local port forwarding stays (CI's tunnels)
#   3. ufw: 22, 80, 443 in; everything else closed (Docker publishes only Caddy beyond 127.0.0.1)
#   4. fail2ban for SSH
#   5. swap (4 GB) and kernel settings
#   6. Docker Engine and the compose plugin (Docker's own apt repository), log rotation
#   7. wal-g (pinned release, checksum checked)
#   8. /opt/carmacars: the compose project, scripts and systemd timers
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D=/opt/carmacars
WALG_VERSION=v3.0.7
WALG_SHA256=146bf51b51930c43c8beac7631323db17e988b9c6a8e87a418fca5c4f3a3b04d   # wal-g-pg-ubuntu-24.04-amd64.tar.gz
say() { echo "[bootstrap] $*"; }

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = ubuntu ] && [ "${VERSION_ID:-}" = 24.04 ] || say "WARNING: written for Ubuntu 24.04, this is ${PRETTY_NAME:-unknown}"
export DEBIAN_FRONTEND=noninteractive
# a fresh install runs cloud-init and unattended-upgrades first: wait for them instead of failing on the apt lock
cloud-init status --wait > /dev/null 2>&1 || true
apt-get() { command apt-get -o DPkg::Lock::Timeout=900 "$@"; }

# ---------------------------------------------------------------- 1. clock, packages, upgrades
timedatectl set-timezone UTC
timedatectl set-ntp true || true
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg jq ufw fail2ban unattended-upgrades apt-listchanges age rsync zstd > /dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52carmacars-unattended <<'EOF'
// security updates every day; never reboot by itself (the database is on this machine): a pending reboot shows in
// the vps-health report (/var/run/reboot-required) and is done by hand in a quiet hour
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Docker's packages restart every container when they upgrade: they are upgraded by hand (CUTOVER.md, Upkeep)
Unattended-Upgrade::Package-Blacklist { "docker-ce"; "docker-ce-cli"; "containerd.io"; "docker-compose-plugin"; "docker-buildx-plugin"; };
EOF
systemctl enable --now unattended-upgrades > /dev/null 2>&1 || true
say "packages and unattended upgrades ready"

# ---------------------------------------------------------------- 2. SSH
install -d -m 755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-carmacars.conf <<'EOF'
# CarmaCars server (infra/vps/bootstrap.sh)
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
# CI reaches Kong, pg-meta and Postgres on 127.0.0.1 through SSH tunnels (scripts/deploy/vps.sh)
AllowTcpForwarding local
ClientAliveInterval 60
ClientAliveCountMax 5
EOF
if ! [ -s /home/ubuntu/.ssh/authorized_keys ]; then
  echo "refusing to lock SSH down: /home/ubuntu/.ssh/authorized_keys is empty" >&2; exit 1
fi
install -d -m 755 /run/sshd   # Ubuntu 24.04 starts sshd by socket: the directory may not exist yet
sshd -t
systemctl reload ssh 2>/dev/null || systemctl restart ssh
say "SSH: keys only"

# ---------------------------------------------------------------- 3. firewall
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw limit 22/tcp > /dev/null
ufw allow 80/tcp > /dev/null
ufw allow 443/tcp > /dev/null
ufw allow 443/udp > /dev/null
ufw --force enable > /dev/null
say "ufw: $(ufw status | grep -c ALLOW) rules (22 limited, 80, 443)"

# ---------------------------------------------------------------- 4. fail2ban
cat > /etc/fail2ban/jail.d/carmacars.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban

# ---------------------------------------------------------------- 5. swap and kernel
if ! swapon --show=NAME --noheadings | grep -q .; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile > /dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  say "swap: 4 GB"
fi
cat > /etc/sysctl.d/90-carmacars.conf <<'EOF'
# CarmaCars server (infra/vps/bootstrap.sh)
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
EOF
sysctl --system > /dev/null

# ---------------------------------------------------------------- 6. Docker
if ! command -v docker > /dev/null || ! docker compose version > /dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin > /dev/null
fi
install -d -m 755 /etc/docker
want_daemon='{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"5"},"live-restore":true}'
if [ "$(jq -c . /etc/docker/daemon.json 2>/dev/null)" != "$(jq -c . <<<"$want_daemon")" ]; then
  echo "$want_daemon" | jq . > /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable docker > /dev/null 2>&1
say "$(docker --version); $(docker compose version)"

# ---------------------------------------------------------------- 7. wal-g
install -d -m 755 "$D/bin"
if ! { [ -x "$D/bin/wal-g" ] && "$D/bin/wal-g" --version 2>/dev/null | grep -q "$WALG_VERSION"; }; then
  t=$(mktemp -d)
  curl -fsSL -o "$t/walg.tgz" "https://github.com/wal-g/wal-g/releases/download/$WALG_VERSION/wal-g-pg-ubuntu-24.04-amd64.tar.gz"
  echo "$WALG_SHA256  $t/walg.tgz" | sha256sum -c - > /dev/null
  tar -C "$t" -xzf "$t/walg.tgz"
  install -m 755 "$t/wal-g-pg-ubuntu-24.04-amd64" "$D/bin/wal-g"
  rm -rf "$t"
fi
say "$("$D/bin/wal-g" --version | head -n 1)"

# ---------------------------------------------------------------- 8. /opt/carmacars
install -d -m 755 "$D" "$D/supabase" "$D/supabase/volumes" "$D/supabase/volumes/api" "$D/supabase/volumes/db" \
  "$D/supabase/volumes/functions" "$D/supabase/volumes/functions/main" "$D/supabase/caddy"
install -d -m 700 "$D/backup" "$D/state"
install -d -m 755 "$D/backup/enabled-flag"
for f in "$SRC"/bin/*; do install -m 755 "$f" "$D/bin/$(basename "$f")"; done
install -m 644 "$SRC/supabase/docker-compose.yml" "$SRC/supabase/defaults.env" "$D/supabase/"
install -m 644 "$SRC/supabase/volumes/api/kong.yml" "$D/supabase/volumes/api/"
install -m 755 "$SRC/supabase/volumes/api/kong-entrypoint.sh" "$D/supabase/volumes/api/"
install -m 644 "$SRC"/supabase/volumes/db/*.sql "$D/supabase/volumes/db/"
install -m 644 "$SRC/supabase/volumes/functions/main/index.ts" "$D/supabase/volumes/functions/main/"
install -m 644 "$SRC/supabase/caddy/Caddyfile" "$D/supabase/caddy/"
# the deployed revision, for the health report
[ -f "$SRC/REVISION" ] && install -m 644 "$SRC/REVISION" "$D/REVISION"
for u in "$SRC"/systemd/*; do install -m 644 "$u" "/etc/systemd/system/$(basename "$u")"; done
systemctl daemon-reload
systemctl enable --now carmacars-wal-push.timer carmacars-walg-base.timer carmacars-storage-backup.timer > /dev/null 2>&1
say "files installed in $D; timers: $(systemctl list-timers 'carmacars-*' --no-legend | wc -l)"
[ -f /var/run/reboot-required ] && say "NOTE: a reboot is pending (kernel or libc update)"
say "done"
