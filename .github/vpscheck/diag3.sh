#!/usr/bin/env bash
# Postgres log errors since go-live, planner statistics after the restore, the slow RPCs' timings.
source .github/vpscheck/common.sh
keys
say "== logging settings"
q <<'SQL' | sayf
select name, setting from pg_settings where name in ('logging_collector','log_destination','log_directory','log_filename','log_min_messages','log_min_error_statement');
SQL
say "== Postgres ERROR lines since go-live (log files), by message"
vps_ssh "sudo bash -c 'd=\$(docker exec supabase-db psql -U supabase_admin -d postgres -XAtc \"select setting from pg_settings where name=\\\$\\\$data_directory\\\$\\\$\"); l=\$(docker exec supabase-db psql -U supabase_admin -d postgres -XAtc \"select setting from pg_settings where name=\\\$\\\$log_directory\\\$\\\$\"); case \$l in /*) ;; *) l=\$d/\$l;; esac; docker exec supabase-db sh -c \"ls -1t \$l | head -5; cat \$l/*.log \$l/*.csv 2>/dev/null\"'" > "$RUNNER_TEMP/pg.log" 2>&1
say "log files: $(head -5 "$RUNNER_TEMP/pg.log" | paste -sd' ' | cut -c1-200)"
awk '$0 >= "2026-10-23 15:15"' "$RUNNER_TEMP/pg.log" | grep -E 'ERROR|FATAL|PANIC' | sed -E 's/^[0-9-]+ [0-9:.]+ [A-Z]+ *//; s/\[[0-9]+\]//g; s/[0-9a-f]{8}-[0-9a-f-]{27}/<uuid>/g; s/\([0-9]+\)/(n)/g; s/"[0-9]+"/"n"/g' | cut -c1-230 | sort | uniq -c | sort -rn | head -30 | sayf
say "== statements behind the errors since 15:52 (STATEMENT lines, function names only)"
awk '$0 >= "2026-10-23 15:52"' "$RUNNER_TEMP/pg.log" | grep -E 'ERROR' -A2 | grep -oE 'public\.[a-z_]+\(|app\.[a-z_]+\(|function [a-z_.]+' | sort | uniq -c | sort -rn | head -15 | sayf
say "== planner statistics: tables never analyzed (of user tables), largest"
q <<'SQL' | sayf
select count(*) filter (where last_analyze is null and last_autoanalyze is null), count(*) from pg_stat_user_tables;
select relname, n_live_tup, last_autoanalyze is not null or last_analyze is not null from pg_stat_user_tables order by n_live_tup desc limit 8;
SQL
rpc_t() { curl -sS -o /dev/null -w "%{http_code} %{time_total}s" --max-time 30 -X POST "$API/rest/v1/rpc/$1" -H "apikey: $2" -H "Authorization: Bearer $2" -H 'content-type: application/json' -d '{}'; }
say "== RPC timings before ANALYZE: site_facts $(rpc_t site_facts "$ANON"); seo_links $(rpc_t seo_links "$ANON"); sitemap_all $(rpc_t sitemap_all "$SERVICE"); place_sitemap_files $(rpc_t place_sitemap_files "$SERVICE")"
say "== again (warm): site_facts $(rpc_t site_facts "$ANON"); seo_links $(rpc_t seo_links "$ANON"); sitemap_all $(rpc_t sitemap_all "$SERVICE"); place_sitemap_files $(rpc_t place_sitemap_files "$SERVICE")"
t0=$(date +%s)
vps_ssh "sudo docker exec supabase-db vacuumdb -U supabase_admin -d postgres --analyze-only --jobs 4 -q" 2>&1 | tail -3 | sayf
say "ANALYZE took $(( $(date +%s) - t0 )) s"
say "== RPC timings after ANALYZE: site_facts $(rpc_t site_facts "$ANON"); seo_links $(rpc_t seo_links "$ANON"); sitemap_all $(rpc_t sitemap_all "$SERVICE"); place_sitemap_files $(rpc_t place_sitemap_files "$SERVICE")"
say "== again: site_facts $(rpc_t site_facts "$ANON"); seo_links $(rpc_t seo_links "$ANON"); sitemap_all $(rpc_t sitemap_all "$SERVICE"); place_sitemap_files $(rpc_t place_sitemap_files "$SERVICE")"
flush diag3
