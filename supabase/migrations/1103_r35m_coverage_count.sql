-- 1103_r35m_coverage_count.sql
-- Release 35, part M (docs/changes/2026-11-08-r35-seo-depth.md, section D). Admin > Settings > Search showed the sample
-- 1% indexed (19 of 1,649) while Search Console showed 172K indexed. The miscount: the share was taken over every
-- address inspected, and two thirds of each sample come from the long tail of the place and vehicle files (millions of
-- addresses), most of them "URL is unknown to Google", so they counted as not indexed. Search Console's 172K indexed
-- and 129K not indexed are of the pages Google knows. The indexed count also read two exact state strings only.
--   1. The run stores its counts by bucket (indexed by verdict PASS or an indexed state; crawled; discovered; unknown to
--      Google; other) and by part of the sample (priority, long tail) (web/scripts/gsc-coverage.mjs).
--   2. The trend gives the share indexed of the addresses Google knows, and of the priority part, and the unknown
--      count apart; older rows (before by_bucket) are read from their states by pattern.
-- No applied migration is edited.

alter table app.gsc_coverage_log
  add column if not exists by_bucket jsonb,   -- {"indexed": 80, "crawled": 30, "discovered": 5, "unknown": 600, "other": 9}
  add column if not exists by_part jsonb;     -- {"priority": {"indexed": 40, ...}, "tail": {...}}

create or replace function app.gsc_coverage_store(p jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare v_id bigint;
begin
  insert into app.gsc_coverage_log (inspected, by_state, by_kind, errors, by_bucket, by_part)
  values (greatest(coalesce((p ->> 'inspected')::integer, 0), 0), coalesce(p -> 'by_state', '{}'::jsonb), coalesce(p -> 'by_kind', '{}'::jsonb),
          greatest(coalesce((p ->> 'errors')::integer, 0), 0), p -> 'by_bucket', p -> 'by_part')
  returning id into v_id;
  delete from app.gsc_coverage_log where at < now() - interval '180 days';
  return v_id;
end $$;

-- a run's buckets: its own, else worked out from its states by pattern (rows before 1103)
create or replace function app.gsc_coverage_buckets(c app.gsc_coverage_log) returns jsonb
language sql immutable as $$
  select coalesce(c.by_bucket, (
    select jsonb_build_object(
      'indexed', coalesce(sum(v) filter (where k ~* 'indexed' and k !~* 'not indexed'), 0),
      'crawled', coalesce(sum(v) filter (where k ~* 'crawled.*not indexed'), 0),
      'discovered', coalesce(sum(v) filter (where k ~* 'discovered.*not indexed'), 0),
      'unknown', coalesce(sum(v) filter (where k ~* 'unknown to google'), 0),
      'other', coalesce(sum(v) filter (where not (k ~* 'indexed' or k ~* 'unknown to google')), 0))
      from (select e.key k, (e.value #>> '{}')::integer v from jsonb_each(c.by_state) e where jsonb_typeof(e.value) = 'number') s))
$$;

create or replace function app.gsc_coverage_trend(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'inspected', d.inspected, 'known', d.inspected - d.unknown, 'indexed', d.indexed, 'crawled', d.crawled,
                                                       'discovered', d.discovered, 'unknown', d.unknown, 'priority_inspected', d.p_n, 'priority_indexed', d.p_ix) order by d.day desc)
    from (select (c.at at time zone 'America/Toronto')::date as day, sum(c.inspected) inspected,
                 sum((app.gsc_coverage_buckets(c) ->> 'indexed')::int) indexed, sum((app.gsc_coverage_buckets(c) ->> 'crawled')::int) crawled,
                 sum((app.gsc_coverage_buckets(c) ->> 'discovered')::int) discovered, sum((app.gsc_coverage_buckets(c) ->> 'unknown')::int) unknown,
                 sum(coalesce((select sum((e.value #>> '{}')::int) from jsonb_each(c.by_part -> 'priority') e where jsonb_typeof(e.value) = 'number'), 0)) p_n,
                 sum(coalesce((c.by_part #>> '{priority,indexed}')::int, 0)) p_ix
            from app.gsc_coverage_log c where c.at > now() - interval '30 days' group by 1) d), '[]'::jsonb);
end $$;

revoke all on function app.gsc_coverage_buckets(app.gsc_coverage_log) from public, anon, authenticated;
grant execute on function app.gsc_coverage_buckets(app.gsc_coverage_log) to service_role;
