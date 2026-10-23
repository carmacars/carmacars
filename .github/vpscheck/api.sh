#!/usr/bin/env bash
# 2. Data API (PostgREST) by role, the anon statement timeout, and 30+ site URLs through the Worker.
source .github/vpscheck/common.sh
keys
say "== PostgREST by role (status time)"
say "anon rpc site_settings_public: $(code_time -X POST "$API/rest/v1/rpc/site_settings_public" -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'content-type: application/json' -d '{}')"
say "anon vehicles select: $(code_time "$API/rest/v1/vehicles?select=id&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON")"
say "anon users select (RLS, expect 200 [] or 401/403): $(curl -sS --max-time 20 "$API/rest/v1/users?select=id&limit=1" -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -w ' %{http_code}' | tail -c 120)"
say "service vehicles count: $(curl -sS --max-time 20 -o /dev/null -D - "$API/rest/v1/vehicles?select=id&limit=1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H 'Prefer: count=exact' | grep -iE '^(HTTP|content-range)' | tr -d '\r' | tr '\n' ' ')"
say "service users count: $(curl -sS --max-time 20 -o /dev/null -D - "$API/rest/v1/users?select=id&limit=1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H 'Prefer: count=exact' | grep -iE '^(HTTP|content-range)' | tr -d '\r' | tr '\n' ' ')"
say "bad key (expect 401): $(code_time "$API/rest/v1/vehicles?select=id&limit=1" -H 'apikey: nope' -H 'Authorization: Bearer nope')"
say "openapi root service (expect 200): $(code_time "$API/rest/v1/" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE")"

say "== anon statement timeout through PostgREST (temporary function public.vpscheck_sleep, dropped after)"
q <<'SQL' | sayf
create or replace function public.vpscheck_sleep(s float8) returns text language sql as $$ select pg_sleep(s)::text || current_setting('statement_timeout') $$;
grant execute on function public.vpscheck_sleep(float8) to anon, authenticated, service_role;
notify pgrst, 'reload schema';
SQL
sleep 4
for role in anon service; do
  k=$ANON; [ $role = service ] && k=$SERVICE
  r=$(curl -sS --max-time 40 -w ' HTTP %{http_code} %{time_total}s' -X POST "$API/rest/v1/rpc/vpscheck_sleep" -H "apikey: $k" -H "Authorization: Bearer $k" -H 'content-type: application/json' -d '{"s": 0.1}')
  say "$role sleep 0.1 (shows its statement_timeout): $(echo "$r" | tail -c 200)"
  r=$(curl -sS --max-time 40 -w ' HTTP %{http_code} %{time_total}s' -X POST "$API/rest/v1/rpc/vpscheck_sleep" -H "apikey: $k" -H "Authorization: Bearer $k" -H 'content-type: application/json' -d '{"s": 6}')
  say "$role sleep 6: $(echo "$r" | tail -c 240)"
done
q <<'SQL' | sayf
drop function if exists public.vpscheck_sleep(float8);
notify pgrst, 'reload schema';
select 'dropped', count(*) = 0 from pg_proc where proname = 'vpscheck_sleep';
SQL

flush api-rest
say "== site through the Worker"
curl -sS --max-time 30 "$SITE/sitemap.xml" -o "$RUNNER_TEMP/sm.xml"
grep -oE '<loc>[^<]+</loc>' "$RUNNER_TEMP/sm.xml" | sed -E 's#</?loc>##g' > "$RUNNER_TEMP/sm-list.txt"
say "sitemap.xml: $(wc -l < "$RUNNER_TEMP/sm-list.txt") locs; child sitemaps:"
: > "$RUNNER_TEMP/urls-all.txt"
while read -r u; do
  if [[ "$u" == *.xml* ]]; then
    res=$(curl -sS --max-time 25 -o "$RUNNER_TEMP/c.xml" -w '%{http_code} %{time_total}s' "$u")
    n=$(grep -c '<loc>' "$RUNNER_TEMP/c.xml" || true)
    say "  $res $n locs ${u#"$SITE"}"
    grep -oE '<loc>[^<]+</loc>' "$RUNNER_TEMP/c.xml" | sed -E 's#</?loc>##g' | shuf -n 4 --random-source=<(yes) >> "$RUNNER_TEMP/urls-all.txt" || true
  else echo "$u" >> "$RUNNER_TEMP/urls-all.txt"; fi
done < <(head -15 "$RUNNER_TEMP/sm-list.txt")
flush api-sitemaps
{ printf '%s\n' "$SITE/" "$SITE/cars" "$SITE/robots.txt" "$SITE/sign-in" "$SITE/list-your-car" "$SITE/investors" "$SITE/no-such-page-vpscheck"; cat "$RUNNER_TEMP/urls-all.txt"; } | awk '!s[$0]++' | head -45 > "$RUNNER_TEMP/urls.txt"
say "== $(wc -l < "$RUNNER_TEMP/urls.txt") URLs: status time cf-cache path"
slow=0; bad=0
while read -r u; do
  r=$(curl -sS -o "$RUNNER_TEMP/p.html" -D "$RUNNER_TEMP/h.txt" -w '%{http_code} %{time_total}' --max-time 20 "$u" 2>/dev/null || echo "000 30")
  cc=$(grep -i '^cf-cache-status' "$RUNNER_TEMP/h.txt" | awk '{print $2}' | tr -d '\r')
  old=$(grep -c 'supabase\.co' "$RUNNER_TEMP/p.html" 2>/dev/null || true)
  newimg=$(grep -o 'api\.carmacars\.ca/storage/v1/object/public/vehicle-public/[^"? )]*' "$RUNNER_TEMP/p.html" | head -1)
  [ -n "$newimg" ] && echo "https://$newimg" >> "$RUNNER_TEMP/imgs.txt"
  code=${r%% *}; t=${r##* }
  [[ "$code" =~ ^(200|404)$ ]] || bad=$((bad+1))
  awk -v t="$t" 'BEGIN{exit !(t>2.5)}' && slow=$((slow+1))
  say "$code ${t}s ${cc:--} old-supabase-refs:$old ${u#"$SITE"}"
done < "$RUNNER_TEMP/urls.txt"
say "unexpected status: $bad; slower than 2.5s: $slow"
say "== photo URLs seen in pages (first 3): status content-type cache-control size time"
sort -u "$RUNNER_TEMP/imgs.txt" 2>/dev/null | head -3 | while read -r i; do
  say "$(curl -sS -o /dev/null -D - -w 'size=%{size_download} %{time_total}s' --max-time 30 "$i" | grep -iE '^(HTTP|content-type|cache-control)|size=' | tr -d '\r' | tr '\n' ' ')"
done
flush api
