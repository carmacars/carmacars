#!/usr/bin/env bash
# 1. Database: pg_cron since go-live, pg_net, vault, role settings, container logs since go-live.
source .github/vpscheck/common.sh
say "== cron jobs since $SINCE: name | schedule | active | ok | failed | running | first | last | last error"
q <<SQL | sayf
select j.jobname, j.schedule, j.active,
  count(d.*) filter (where d.status = 'succeeded'), count(d.*) filter (where d.status = 'failed'),
  count(d.*) filter (where d.status in ('running','starting','sending','connecting')),
  to_char(min(d.start_time) at time zone 'UTC', 'HH24:MI'), to_char(max(d.start_time) at time zone 'UTC', 'HH24:MI'),
  left(regexp_replace(coalesce((array_agg(d.return_message order by d.start_time desc) filter (where d.status = 'failed'))[1], ''), '\s+', ' ', 'g'), 220)
from cron.job j left join cron.job_run_details d on d.jobid = j.jobid and d.start_time >= '$SINCE'
group by j.jobname, j.schedule, j.active order by (count(d.*) filter (where d.status = 'failed')) desc, j.jobname;
SQL
say "== totals: jobs, active, run rows since go-live, failed rows, now (UTC)"
q <<SQL | sayf
select (select count(*) from cron.job), (select count(*) from cron.job where active),
  (select count(*) from cron.job_run_details where start_time >= '$SINCE'),
  (select count(*) from cron.job_run_details where start_time >= '$SINCE' and status = 'failed'), to_char(now() at time zone 'UTC','HH24:MI:SS');
SQL
say "== active jobs with no successful run since go-live"
q <<SQL | sayf
select j.jobname, j.schedule from cron.job j where j.active and not exists
 (select 1 from cron.job_run_details d where d.jobid = j.jobid and d.start_time >= '$SINCE' and d.status = 'succeeded') order by 1;
SQL
say "== pg_net responses since go-live: status | timed_out | error | count"
q <<SQL | sayf
select status_code, timed_out, left(coalesce(error_msg,''), 160), count(*) from net._http_response where created >= '$SINCE' group by 1,2,3 order by 4 desc;
select 'queue', count(*) from net.http_request_queue;
SQL
say "== pg_net non-2xx bodies (first 160 chars)"
q <<SQL | sayf
select status_code, left(regexp_replace(content, '\s+', ' ', 'g'), 160), count(*) from net._http_response
 where created >= '$SINCE' and (status_code is null or status_code >= 300) group by 1,2 order by 3 desc limit 15;
SQL
say "== vault: secrets, decrypted non-null, null"
q <<'SQL' | sayf
select count(*), count(decrypted_secret), count(*) - count(decrypted_secret) from vault.decrypted_secrets;
SQL
say "== role settings (rolconfig) and database settings"
q <<'SQL' | sayf
select rolname, array_to_string(rolconfig, ', ') from pg_roles where rolname in ('anon','authenticated','service_role','authenticator','postgres','supabase_storage_admin','supabase_auth_admin') order by 1;
select 'db', array_to_string(setconfig, ', ') from pg_db_role_setting where setdatabase = (select oid from pg_database where datname='postgres') and setrole = 0;
select name, setting from pg_settings where name in ('statement_timeout','max_connections','shared_buffers','ssl','archive_mode','archive_command','wal_level','cron.timezone','log_min_duration_statement','idle_in_transaction_session_timeout');
select 'version', version();
SQL
say "== connections by user/state"
q <<'SQL' | sayf
select usename, state, count(*) from pg_stat_activity where backend_type = 'client backend' group by 1,2 order by 3 desc;
SQL
say "== migrations: last 3"
q <<'SQL' | sayf
select version, name from supabase_migrations.schema_migrations order by version desc limit 3;
SQL
for c in db auth rest storage functions kong meta caddy; do
  say "== logs $c since go-live: lines, error-ish lines; top messages"
  vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since $SINCE_ISO $c 2>&1" > "$RUNNER_TEMP/$c.log" || true
  total=$(wc -l < "$RUNNER_TEMP/$c.log")
  if [ "$c" = kong ] || [ "$c" = caddy ]; then
    grep -E '" (5[0-9]{2}) ' "$RUNNER_TEMP/$c.log" > "$RUNNER_TEMP/$c.err" || true
    [ "$c" = caddy ] && { grep -E '"status":5[0-9]{2}|"level":"error"' "$RUNNER_TEMP/$c.log" > "$RUNNER_TEMP/$c.err" || true; }
  else
    grep -iE 'ERROR|FATAL|PANIC|"level":"(error|fatal)"|level=error|\berr\b|exception|uncaught' "$RUNNER_TEMP/$c.log" | grep -viE 'error_msg|errors?=0|"error":null' > "$RUNNER_TEMP/$c.err" || true
  fi
  say "$c: $total lines, $(wc -l < "$RUNNER_TEMP/$c.err") error-ish"
  sed -E -e 's/^[0-9T:. -]+(UTC|Z)? *//' -e 's/"(time|timestamp|ts|request_id|remote_addr|referer|component)":"[^"]*",?//g' -e 's/[0-9a-f]{8}-[0-9a-f-]{27}/<uuid>/g' -e 's/\[[0-9]+\]/[n]/g' -e 's/[0-9]+(\.[0-9]+)?(ms|s)\b/<t>/g' "$RUNNER_TEMP/$c.err" \
    | cut -c1-260 | sort | uniq -c | sort -rn | head -12 | sayf
done
flush db
