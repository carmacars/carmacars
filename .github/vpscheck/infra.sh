#!/usr/bin/env bash
# 7/9. Backups, health, exposure, and what hosted Supabase gave that this server may not.
source .github/vpscheck/common.sh
H=$(vps_host)
say "== health-local"
vps_ssh sudo /opt/carmacars/bin/health-local 2>&1 | jq -c . 2>/dev/null | cut -c1-1500 | sayf
say "== containers"
vps_ssh "sudo docker ps --format '{{.Names}} {{.Status}}'" 2>&1 | sayf
say "== wal-g: backups and archive"
vps_ssh "sudo /opt/carmacars/bin/walg backup-list 2>&1 | tail -4; ls /opt/carmacars 2>/dev/null; sudo systemctl list-timers --all --no-pager 2>/dev/null | grep -iE 'wal|backup' ; sudo systemctl is-active carmacars-wal-push.timer carmacars-walg-base.timer 2>&1 | paste -sd' '" 2>&1 | cut -c1-200 | sayf
q <<'SQL' | sayf
select 'archiver', archived_count, last_archived_wal, to_char(last_archived_time at time zone 'UTC','MM-DD HH24:MI:SS'), failed_count, last_failed_wal, to_char(last_failed_time at time zone 'UTC','MM-DD HH24:MI:SS') from pg_stat_archiver;
select 'current wal', pg_walfile_name(pg_current_wal_lsn()), to_char(now() at time zone 'UTC','HH24:MI:SS');
SQL
say "== exposure from the internet (expect only 22, 80, 443 open)"
for p in 22 80 443 5432 6543 8000 8443 3000 8085 54321 4000 9999; do
  if timeout 5 bash -c "</dev/tcp/$H/$p" 2>/dev/null; then say "port $p OPEN"; else say "port $p closed"; fi
done
say "http->https: $(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 http://api.carmacars.ca/rest/v1/)"
say "tls: $(echo | openssl s_client -connect api.carmacars.ca:443 -servername api.carmacars.ca 2>/dev/null | openssl x509 -noout -issuer -enddate | paste -sd' ')"
say "tls1.1 refused: $(curl -sS -o /dev/null -w '%{http_code}' --tls-max 1.1 --max-time 10 https://api.carmacars.ca/auth/v1/health 2>&1 | tail -c 80)"
say "studio/meta via public kong (expect 404/401): pg/meta $(code_time https://api.carmacars.ca/pg/query) ; /project/default $(code_time https://api.carmacars.ca/project/default)"
say "== Postgres SSL, listen, ufw, fail2ban, unattended upgrades, reboot-required"
q <<'SQL' | sayf
select name, setting from pg_settings where name in ('ssl','listen_addresses','password_encryption');
SQL
vps_ssh "sudo ufw status | head -12; sudo fail2ban-client status 2>/dev/null | tail -2; systemctl is-active unattended-upgrades; test -f /var/run/reboot-required && echo REBOOT-REQUIRED || echo no-reboot-required; df -h / | tail -1; free -m | sed -n 2p; uptime" 2>&1 | sayf
say "== backups in the bucket (logical) and schedules"
vps_ssh "sudo ls -la --time-style=+%m-%dT%H:%M /opt/carmacars/state 2>/dev/null" 2>&1 | cut -c1-160 | sayf
flush infra
