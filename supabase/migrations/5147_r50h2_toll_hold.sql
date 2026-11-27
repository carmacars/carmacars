-- 5147 (R50 hotfix 2, review fix, docs/changes/2026-11-27-r50-hotfix2-ops.md): a statement that may be wrong is never charged
-- by itself. The reader (web/src/features/tolls/parse.ts, ReadResult.hold) lists what stops it: a credit or reversal it left
-- out, and lines that do not add up to the statement's total. Before, those were only warnings and the confirm still charged
-- the high matches.
-- Now: toll_notice_reads.charge_hold keeps that list (app.toll_read_save stores the read's "hold"). While it is not empty,
-- app.toll_read_confirm and app.toll_read_line_import import the lines but charge nothing, and a Finance To do
-- (toll_read_hold) lists the items for a person. A person who has checked them confirms with release_hold: then the
-- read charges as before, and who released it is in the audit log.
-- No applied migration is edited. SCHEMA_MARKER 5147.
set local check_function_bodies = off;

alter table toll_notice_reads add column if not exists charge_hold text[] not null default '{}';
comment on column toll_notice_reads.charge_hold is '5147: what stops this read charging by itself (a credit left out, lines that do not add up to the statement); empty: none.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('toll_read_hold', 'finance', 'A toll statement was not charged: check it', 'high', 'business_days', 1, 11, null,
   'The statement has a credit the reader left out, or its lines do not add up to its total. Check each item against the statement, then charge the matched lines from Tolls and tickets')
on conflict (task_type) do nothing;

alter function app.toll_read_save(uuid, jsonb) rename to toll_read_save_pre5147;
create function app.toll_read_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r jsonb := app.toll_read_save_pre5147(p_by, p);
  v_hold text[] := coalesce((select array_agg(left(e, 300)) from jsonb_array_elements_text(case when jsonb_typeof(p -> 'hold') = 'array' then p -> 'hold' else '[]'::jsonb end) e), '{}');
begin
  if cardinality(v_hold) = 0 then return r; end if;
  update toll_notice_reads set charge_hold = v_hold where id = (r ->> 'id')::uuid;
  return app.toll_read_get(p_by, (r ->> 'id')::uuid);
end $$;

alter function app.toll_read_confirm(uuid, jsonb) rename to toll_read_confirm_pre5147;
create function app.toll_read_confirm(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r toll_notice_reads;
  v_release boolean := coalesce((p ->> 'release_hold')::boolean, false);
  v_out jsonb;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin confirms a read' using errcode = '42501'; end if;
  select * into r from toll_notice_reads where id = (p ->> 'read')::uuid;
  if r.id is null or cardinality(r.charge_hold) = 0 then return app.toll_read_confirm_pre5147(p_by, p); end if;
  if v_release then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'toll_read_hold_release', 'toll_notice_reads', r.id::text, jsonb_build_object('hold', to_jsonb(r.charge_hold)));
    update toll_notice_reads set charge_hold = '{}' where id = r.id;
    return app.toll_read_confirm_pre5147(p_by, p);
  end if;
  -- held: the lines are imported, nothing is charged, a person checks the items
  v_out := app.toll_read_confirm_pre5147(p_by, p || jsonb_build_object('charge', false));
  perform app.raise_task(p_type => 'toll_read_hold', p_title => format('%s was not charged: check %s item%s', r.read_number, cardinality(r.charge_hold), case when cardinality(r.charge_hold) = 1 then '' else 's' end),
      p_detail => array_to_string(r.charge_hold, E'\n'), p_related_table => 'toll_notice_reads', p_related_id => r.id, p_created_by => p_by,
      p_dedupe => 'toll_read_hold:' || r.id, p_due_at => app.add_business_days(app.today(), 1)::timestamptz);
  return v_out || jsonb_build_object('held', to_jsonb(r.charge_hold));
end $$;

alter function app.toll_read_line_import(uuid, jsonb) rename to toll_read_line_import_pre5147;
create function app.toll_read_line_import(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  -- a line of a held statement is imported without a charge
  if exists (select 1 from toll_notice_read_lines l join toll_notice_reads r on r.id = l.read_id where l.id::text = p ->> 'line' and cardinality(r.charge_hold) > 0) then
    return app.toll_read_line_import_pre5147(p_by, p || jsonb_build_object('charge', false));
  end if;
  return app.toll_read_line_import_pre5147(p_by, p);
end $$;

comment on function app.toll_read_save(uuid, jsonb) is '5147: a read saved with what holds its charging (charge_hold).';
comment on function app.toll_read_confirm(uuid, jsonb) is '5147: a held read is imported without charging and a Finance To do lists the items; release_hold after a person checked them.';
comment on function app.toll_read_line_import(uuid, jsonb) is '5147: a line of a held read is imported without a charge.';

revoke all on function app.toll_read_save(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.toll_read_confirm(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.toll_read_line_import(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.toll_read_save_pre5147(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.toll_read_confirm_pre5147(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.toll_read_line_import_pre5147(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.toll_read_save(uuid, jsonb), app.toll_read_confirm(uuid, jsonb), app.toll_read_line_import(uuid, jsonb),
  app.toll_read_save_pre5147(uuid, jsonb), app.toll_read_confirm_pre5147(uuid, jsonb), app.toll_read_line_import_pre5147(uuid, jsonb) to service_role;
