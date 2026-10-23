#!/usr/bin/env bash
# Follow-ups: SMTP failure, failed writes since go-live, leftovers.
source .github/vpscheck/common.sh
say "== leftovers"
q <<'SQL' | sayf
drop function if exists public.vpscheck_sleep(float8);
notify pgrst, 'reload schema';
select 'vpscheck users left', count(*) from auth.users where email like 'rent+vpscheck%';
SQL
say "== GoTrue SMTP settings (names; sender address domain only)"
vps_ssh "sudo grep -E '^GOTRUE_(SMTP_[A-Z_]+|MAILER_[A-Z_]+)=' /opt/carmacars/supabase/auth.env | grep -vE 'TEMPLATES|SUBJECTS' | sed -E 's/^(GOTRUE_SMTP_(PASS|USER))=.*/\1=<set>/'; sudo grep -E '^GOTRUE_MAILER_TEMPLATES_[A-Z_]+=' /opt/carmacars/supabase/auth.env | cut -c1-120" 2>&1 | sed -E 's/@([a-z.]+)/@\1/' | sayf
say "== env inside the auth container (SMTP names only)"
vps_ssh "sudo docker exec supabase-auth env | grep -E '^GOTRUE_SMTP|^GOTRUE_MAILER_(AUTOCONFIRM|URLPATHS|EXTERNAL)' | sed -E 's/=(.{0,3}).*/=\1…/'" 2>&1 | sayf
say "== TCP from the server to smtp.resend.com (465, 587, 2465, 2587)"
for p in 465 587 2465 2587; do
  say "$p: $(vps_ssh "sudo docker exec supabase-auth sh -c 'timeout 6 nc -z -w 5 smtp.resend.com $p && echo open || echo closed' 2>&1; timeout 6 bash -c '</dev/tcp/smtp.resend.com/$p' 2>/dev/null && echo host-open || echo host-closed" 2>&1 | paste -sd' ')"
done
say "== GoTrue errors since go-live (mail)"
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since $SINCE_ISO auth 2>&1" > "$RUNNER_TEMP/auth.log" || true
grep -iE 'mail|smtp|recovery|confirmation|invite' "$RUNNER_TEMP/auth.log" | grep -iE 'error|fail|warn' | jq -r '[.level, .msg, .error, .path, .status] | map(tostring) | join(" | ")' 2>/dev/null | cut -c1-400 | sort | uniq -c | sort -rn | head -12 | sayf
say "== Postgres errors since go-live by message (dup keys = the sequence problem)"
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since $SINCE_ISO db 2>&1" > "$RUNNER_TEMP/db.log" || true
grep -E 'ERROR:|FATAL:|PANIC:' "$RUNNER_TEMP/db.log" | sed -E 's/^.*(ERROR|FATAL|PANIC):  ?/\1: /' | sed -E 's/\([0-9]+\)/(n)/g; s/[0-9a-f]{8}-[0-9a-f-]{27}/<uuid>/g' | cut -c1-200 | sort | uniq -c | sort -rn | head -25 | sayf
say "== which statements hit the duplicate audit/app_events ids (first context line, by function)"
grep -A3 'duplicate key value violates unique constraint' "$RUNNER_TEMP/db.log" | grep -E 'STATEMENT:|CONTEXT:' | sed -E 's/^.*(STATEMENT|CONTEXT):  ?//' | grep -oE '(select|SELECT) +[a-z_.]+\(|PL/pgSQL function [a-z_.]+|insert into [a-z_.]+|update [a-z_.]+|rpc/[a-z_]+|"[a-z_]+"\.' | sort | uniq -c | sort -rn | head -25 | sayf
say "== PostgREST 4xx/5xx since go-live (kong) by path"
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since $SINCE_ISO kong 2>&1" | grep -E '" (4[0-9]{2}|5[0-9]{2}) ' | grep -oE '"(GET|POST|PATCH|DELETE|PUT|HEAD) [^ ?]+[^"]*" [0-9]{3}' | sed -E 's/\?[^ ]*//; s#/(object|sign)/(public|authenticated|sign)?/?([a-z-]+)/.*" #/\1/\2/\3/… " #; s/[0-9a-f]{8}-[0-9a-f-]{27}/<uuid>/g' | sort | uniq -c | sort -rn | head -25 | sayf
say "== storage errors (level 50) since go-live"
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since $SINCE_ISO storage 2>&1" | grep '"level":50' | jq -r '[.req.method, (.req.url|split("?")[0]|sub("/[^/]+$";"/…")), .res.statusCode, (.error.message // .err.message // .msg)] | map(tostring) | join(" | ")' 2>/dev/null | sort | uniq -c | sort -rn | head -10 | sayf
say "== rows created since go-live"
for t in bookings app_events notification_outbox audit_log users booking_requests visitors webhook_events; do
  say "$t: $(q <<<"select count(*) from $t where created_at >= '$SINCE'" | tail -1 | cut -c1-120)"
done
flush diag
