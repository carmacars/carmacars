#!/usr/bin/env bash
# 4. Storage: buckets, policies, public photo, signed links (private buckets), upload + delete.
source .github/vpscheck/common.sh
keys
SH=(-H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE")
say "== buckets: id | public | size limit | mime types | objects | bytes"
q <<'SQL' | sayf
select b.id, b.public, b.file_size_limit, array_length(b.allowed_mime_types,1), count(o.id), coalesce(sum((o.metadata->>'size')::bigint),0)
from storage.buckets b left join storage.objects o on o.bucket_id = b.id group by 1,2,3,4 order by 1;
select 'policies on storage.objects', count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects';
select 'policies on storage.buckets', count(*) from pg_policies where schemaname = 'storage' and tablename = 'buckets';
select 'storage migrations', count(*) from storage.migrations;
SQL
say "== files on disk vs rows"
vps_ssh "sudo bash -c 'cd /opt/carmacars/supabase/volumes/storage 2>/dev/null && find . -type f | wc -l; du -sh . | cut -f1'" 2>&1 | paste -sd' ' | sed 's/^/files, size: /' | sayf
say "== storage API"
say "status: $(code_time "$API/storage/v1/status")"
say "bucket list (service): $(curl -sS --max-time 20 "$API/storage/v1/bucket" "${SH[@]}" | jq -r 'if type=="array" then (map(.id)|join(",")) else tostring end' | cut -c1-300)"
pick() { q <<<"select name from storage.objects where bucket_id = '$1' and coalesce(metadata->>'mimetype','') like '$2' order by created_at desc limit 1" | head -1; }
P=$(pick vehicle-public 'image/%')
if [ -n "$P" ]; then
  enc=$(jq -rn --arg p "$P" '$p|split("/")|map(@uri)|join("/")')
  say "public photo (newest) 1st: $(curl -sS -o /dev/null -D - -w 'size=%{size_download} %{time_total}s' --max-time 30 "$API/storage/v1/object/public/vehicle-public/$enc" | grep -iE '^(HTTP|content-type|cache-control|etag|last-modified)|size=' | tr -d '\r' | tr '\n' ' ')"
  say "public photo 2nd: $(curl -sS -o /dev/null -D - -w 'size=%{size_download} %{time_total}s' --max-time 30 "$API/storage/v1/object/public/vehicle-public/$enc" | grep -iE '^(HTTP|content-type|cache-control)|size=' | tr -d '\r' | tr '\n' ' ')"
  say "public photo HEAD: $(code_time -I "$API/storage/v1/object/public/vehicle-public/$enc")"
  say "public photo via render/image (transformations; imgproxy not deployed): $(code_time "$API/storage/v1/render/image/public/vehicle-public/$enc?width=200")"
fi
say "random 10 public photos: $(q <<<"select name from storage.objects where bucket_id='vehicle-public' order by random() limit 10" | while read -r n; do e=$(jq -rn --arg p "$n" '$p|split("/")|map(@uri)|join("/")'); curl -sS -o /dev/null -w '%{http_code}:%{content_type} ' --max-time 20 "$API/storage/v1/object/public/vehicle-public/$e"; done)"
for spec in "documents|%" "investor-media|video/%" "investor-media|%" "agreements|%" "identity|%" "condition-photos|%" "vehicle-originals|%"; do
  b=${spec%%|*}; m=${spec#*|}
  n=$(pick "$b" "$m"); [ -n "$n" ] || { say "signed $b ($m): no object"; continue; }
  enc=$(jq -rn --arg p "$n" '$p|split("/")|map(@uri)|join("/")')
  s=$(curl -sS --max-time 20 -X POST "$API/storage/v1/object/sign/$b/$enc" "${SH[@]}" -H 'content-type: application/json' -d '{"expiresIn":120}' | jq -r '.signedURL // .signedUrl // empty')
  if [ -z "$s" ]; then say "signed $b: sign FAILED"; continue; fi
  u="$API/storage/v1${s#/storage/v1}"; [[ "$s" == /* ]] || u="$API/storage/v1/$s"
  say "signed $b ($m): $(curl -sS -o /dev/null -D - -r 0-1023 -w 'got=%{size_download} %{time_total}s' --max-time 30 "$u" | grep -iE '^(HTTP|content-type|content-range|cache-control)|got=' | tr -d '\r' | tr '\n' ' ')"
  say "  public URL of private $b (expect 400/404): $(code_time "$API/storage/v1/object/public/$b/$enc")"
  say "  tampered token (expect 400): $(code_time "${u%?????}xxxxx")"
done
say "== upload, read, signed upload link, delete (documents/vpscheck/$RUN/*)"
K="vpscheck/$RUN/test.txt"
say "upload (service): $(code_time -X POST "$API/storage/v1/object/documents/$K" "${SH[@]}" -H 'content-type: text/plain' -H 'x-upsert: true' --data-binary "vpscheck $RUN")"
say "read authenticated: $(curl -sS --max-time 20 "$API/storage/v1/object/authenticated/documents/$K" "${SH[@]}")"
up=$(curl -sS --max-time 20 -X POST "$API/storage/v1/object/upload/sign/documents/vpscheck/$RUN/browser.txt" "${SH[@]}" -H 'x-upsert: true' | jq -r '.url // empty')
say "signed upload link: ${up:+issued}"
[ -n "$up" ] && say "PUT to signed upload link (the browser path): $(curl -sS --max-time 20 -X PUT "$API/storage/v1${up#/storage/v1}" -H 'content-type: text/plain' -H 'x-upsert: true' --data-binary "browser $RUN" -w ' %{http_code}' | tail -c 160)"
say "rows now: $(q <<<"select count(*) from storage.objects where bucket_id='documents' and name like 'vpscheck/$RUN/%'")"
say "delete: $(curl -sS --max-time 20 -X DELETE "$API/storage/v1/object/documents" "${SH[@]}" -H 'content-type: application/json' -d "{\"prefixes\":[\"$K\",\"vpscheck/$RUN/browser.txt\"]}" -w ' %{http_code}' | jq -Rr '.' | tail -c 60)"
say "rows after delete (expect 0): $(q <<<"select count(*) from storage.objects where bucket_id='documents' and name like 'vpscheck/%'")"
say "on disk after delete: $(vps_ssh "sudo find /opt/carmacars/supabase/volumes/storage -path '*vpscheck*' | wc -l" 2>&1)"
flush storage
