-- 2783_r44_statement_period.sql
-- Release 44. Owner statement periods:
--   1. The first period of an owner started at their earliest booking of any kind, so a booking hidden from the owner (an
--      insurer replacement hidden from them, "never" shown, or not part of their revenue) set the start ("Sep 2 to Nov 7"),
--      which told the owner a booking existed. It now starts at the first booking the owner sees and that counts for them, or
--      the program start of their car (its enrollment date), whichever is first. Every owner's first statement (any status
--      but void) is put right once; later periods start the day after the previous one, as before.
--   2. A statement whose period is shorter than a full period (the day after the cutoff of the month before through the
--      cutoff) is a partial month: app.owner_statement_partial(statement). The statement for Admin and the PDF
--      (owner_statement_breakdown) and the owner portal's statement (owner_portal_statement) carry partial_month and the
--      period; the pages and the PDF say "This statement covers a partial month (Oct 24 to Nov 7, 2026), not a full month."
--      A stored PDF of such a statement is made again on its next download, so the issued ones carry the notice too.
-- No applied migration is edited: functions are replaced with the same signature or wrapped (_pre2783).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. where the first period starts
-- a booking the owner sees and that counts for them (2480's rule; "never" shown is hidden too)
create function app.booking_visible_to_owner(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.booking_counts_for_owner(b) and coalesce(b.owner_visibility, 'shown') <> 'never'
$$;

create or replace function app.statement_period_start(p_owner uuid, p_month date) returns date
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select max(coalesce(s.period_ends_on, app.statement_period_end(s.statement_month))) + 1 from owner_statements s
      where s.owner_id = p_owner and s.status <> 'void' and s.statement_month < app.month_start(p_month)),
    -- 2783: the first visible booking or the car's program start, whichever is first; a hidden booking never sets it
    (select min(d) from (
       select min(app.local_date(b.pickup_at)) as d from bookings b join booking_splits x on x.booking_id = b.id
        where x.owner_id = p_owner and x.status <> 'reversed' and x.payout_month < date '9999-01-01' and app.booking_visible_to_owner(b)
       union all
       select min(v.enrollment_date) from vehicles v where v.owner_id = p_owner and v.enrollment_date is not null
         and v.enrollment_date <= app.statement_period_end(p_month)) q),
    app.statement_period_end((app.month_start(p_month) - interval '1 month')::date) + 1)
$$;

-- every owner's first statement, once (an approved one too: the period is how it reads, not what it pays)
update owner_statements s set period_starts_on = app.statement_period_start(s.owner_id, s.statement_month)
 where s.status <> 'void'
   and not exists (select 1 from owner_statements p where p.owner_id = s.owner_id and p.status <> 'void' and p.statement_month < s.statement_month)
   and s.period_starts_on is distinct from app.statement_period_start(s.owner_id, s.statement_month);

-- ================================================================ 2. a partial month
create function app.owner_statement_partial(p_statement uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(s.period_starts_on > (s.period_ends_on - interval '1 month')::date + 1, false)
    from owner_statements s where s.id = p_statement
$$;
comment on function app.owner_statement_partial(uuid) is 'Owner statements (2783): true when the statement''s period is shorter than a full period (it starts after the day following the cutoff of the month before), as a car''s first statement usually is. web/src/features/owner/period.ts partialMonth has the same rule.';

alter function app.owner_statement_breakdown(uuid, uuid) rename to owner_statement_breakdown_pre2783;
create function app.owner_statement_breakdown(p_statement uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x.r is null then x.r else x.r || jsonb_build_object('statement_month', s.statement_month, 'period_starts_on', s.period_starts_on,
           'period_ends_on', s.period_ends_on, 'partial_month', app.owner_statement_partial(s.id)) end
    from (select app.owner_statement_breakdown_pre2783(p_statement, p_by) as r) x left join owner_statements s on s.id = p_statement
$$;
select pg_temp.copy_grants('app.owner_statement_breakdown(uuid, uuid)'::regprocedure, 'app.owner_statement_breakdown_pre2783(uuid, uuid)'::regprocedure);

alter function app.owner_portal_statement(uuid, uuid) rename to owner_portal_statement_pre2783;
create function app.owner_portal_statement(p_by uuid, p_statement uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x.r is null or jsonb_typeof(x.r) <> 'object' then x.r else x.r || jsonb_build_object('partial_month', app.owner_statement_partial(p_statement),
           'period_starts_on', s.period_starts_on, 'period_ends_on', s.period_ends_on) end
    from (select app.owner_portal_statement_pre2783(p_by, p_statement) as r) x left join owner_statements s on s.id = p_statement
$$;
select pg_temp.copy_grants('app.owner_portal_statement(uuid, uuid)'::regprocedure, 'app.owner_portal_statement_pre2783(uuid, uuid)'::regprocedure);

-- the stored PDF of a partial-month statement is made again on its next download (the same file path; the emailed links
-- keep working and show the new file)
update owner_statements s set document_id = null
 where app.owner_statement_partial(s.id) and s.document_id is not null
   and exists (select 1 from generated_documents g where g.kind = 'owner_statement' and g.entity_key = s.id::text and g.document_id = s.document_id);
delete from generated_documents g using owner_statements s
 where g.kind = 'owner_statement' and g.entity_key = s.id::text and app.owner_statement_partial(s.id);

revoke all on function app.booking_visible_to_owner(bookings), app.owner_statement_partial(uuid), app.owner_statement_breakdown_pre2783(uuid, uuid),
  app.owner_portal_statement_pre2783(uuid, uuid) from public, anon, authenticated;
grant execute on function app.booking_visible_to_owner(bookings), app.owner_statement_partial(uuid) to service_role;
