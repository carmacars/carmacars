#!/usr/bin/env bash
# Read only, run on the server by `web-vps.sh tls-report` (deploy-vps action=test): what Caddy hands out per hostname.
# Argument: the domain. Prints no secret (certificate names and dates, Caddy's certificate log lines).
set +e
dom="${1:?domain}"; S=/opt/carmacars/supabase; O="$S/caddy/sites/origin/cert.pem"
echo "[tls] caddy: $(docker exec supabase-caddy caddy version 2>&1 | head -1)"
echo "[tls] origin cert: $(openssl x509 -in "$O" -noout -enddate -ext subjectAltName 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
echo "[tls] site files: $(ls "$S/caddy/sites" | tr '\n' ' ')"
echo "[tls] tls lines: $(grep -h '^[[:space:]]*tls ' "$S"/caddy/sites/*.caddy "$S/caddy/Caddyfile" 2>/dev/null | tr -s ' \t' ' ' | tr '\n' ';')"
echo "[tls] API_HOSTNAME: $(grep -m1 '^API_HOSTNAME=' "$S/defaults.env" | cut -d= -f2)"
for h in "api.$dom" "meet.$dom" "new.$dom" "$dom"; do
  c=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$h" 2>&1)
  echo "[tls] server $h: $(grep -E '^(subject|issuer)=|Verify return code|alert' <<<"$c" | tr '\n' ' ')"
  echo "[tls] server $h cert: $(openssl x509 -noout -enddate -ext subjectAltName <<<"$c" 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
done
echo "[tls] port 80 for api (challenge path): $(curl -s -o /dev/null -w '%{http_code}' -H "Host: api.$dom" http://127.0.0.1/.well-known/acme-challenge/probe)"
echo "[tls] caddy data certificates: $(docker exec supabase-caddy sh -c 'ls /data/caddy/certificates/*/ 2>/dev/null' | tr '\n' ' ')"
docker logs supabase-caddy --since 72h 2>&1 | grep -vF 'http.log' | grep -iE 'tls|acme|certificate|obtain|renew|challenge' | tail -40 | cut -c1-500 | sed 's/^/[tls] log: /'
