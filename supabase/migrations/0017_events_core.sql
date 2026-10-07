-- 0017_events_core.sql
-- One place where the platform records "something happened that people may need to hear about".
-- Any function or trigger calls app.emit_event(). The notification layer (a later migration)
-- reads app_events and decides who is emailed, what goes into a digest and what becomes an
-- in-app notice. Emitting an event never sends anything by itself and never fails the caller's
-- business rule: it is a plain insert in the same transaction.
--
-- code      the event name. For anything that maps to an email it is the email catalogue code
--           (emails/catalogue.json), for example 'renter_offer_ready'.
-- entity    the table the event is about ('booking', 'owner_invoice', 'toll_ticket', ...).
-- entity_id the row.
-- payload   extra values the templates need that cannot be read from the row later.
-- dedupe_key when set, the same key is recorded once only (a retry or a job run twice is harmless).

create table app_events (
  id           bigint generated always as identity primary key,
  code         text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  entity       text not null,
  entity_id    uuid,
  payload      jsonb not null default '{}'::jsonb,
  dedupe_key   text unique,
  actor_user_id uuid references users (id),
  created_at   timestamptz not null default now(),
  processed_at timestamptz,
  process_note text
);
create index app_events_unprocessed_idx on app_events (id) where processed_at is null;
create index app_events_entity_idx on app_events (entity, entity_id);
comment on table app_events is 'Append-only list of business events. Read by the notification layer. Written only through app.emit_event().';

create or replace function app.emit_event(
  p_code text, p_entity text, p_entity_id uuid,
  p_payload jsonb default '{}'::jsonb, p_dedupe_key text default null)
returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint;
begin
  insert into app_events (code, entity, entity_id, payload, dedupe_key, actor_user_id)
  values (p_code, p_entity, p_entity_id, coalesce(p_payload, '{}'::jsonb), p_dedupe_key, app.uid())
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;   -- null when the dedupe key was already recorded
end $$;

alter table app_events enable row level security;
create policy admin_all on app_events for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on app_events from anon, authenticated;
grant select on app_events to authenticated;
grant all on app_events to service_role;
revoke all on function app.emit_event(text, text, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function app.emit_event(text, text, uuid, jsonb, text) to service_role;
