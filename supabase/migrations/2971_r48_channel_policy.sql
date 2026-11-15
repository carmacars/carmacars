-- 2971 (release 48): fewer texts, more email. A channel for each message type (text, email or both).
--
-- The owner's request (Nov 14): texts cost money and most messages read just as well by email. Program settings now
-- show each message type that can go by text, how many texts it sent in the last 30 days, and its channel:
--   email   email only; a text only when the person has no email address or theirs is bounced or suppressed
--   text    text only (an email when the text cannot go, as before; documents that always go by email still do)
--   both    as before: the person's own choice of text, email or both
-- The defaults apply once program_settings.email_production_ready is on (Amazon SES out of its sandbox): the urgent
-- types keep their texts (the pickup details and codes, the late return, a failed payment, a declined deposit), every
-- other type goes by email only. While it is off nothing changes. Texts sent outside the notifications (the deposit
-- link, sign-in codes, staff alerts, texts typed by staff) always stay texts: they are listed with their counts only.
--   message_channel_policy        one row per type the Admin changed (else the default)
--   app.channel_policy_for(code)  the channel in force (null: as before)
--   app.notify_route              the routing trigger of 0096 follows it (patched)
--   app.outbox_record_bounce      an email of an email-only type that bounces is sent by text instead (wrapped)
--   admin_read channel_policy     the list with the counts; admin_do channel_policy_set {code, channel | null}
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2971: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the switch and the table
alter table program_settings add column if not exists email_production_ready boolean not null default false;
comment on column program_settings.email_production_ready is 'r48 (2971): Amazon SES is out of its sandbox and email reaches everyone. On: each message type follows its channel (Program settings, Texts and email by message type): urgent types keep their texts, the others go by email only. Off: as before.';

create table if not exists message_channel_policy (
  code        text primary key,
  channel     text not null check (channel in ('text', 'email', 'both')),
  updated_by  uuid references users (id) on delete set null,
  updated_at  timestamptz not null default now()
);
create index if not exists message_channel_policy_updated_by_idx on message_channel_policy (updated_by) where updated_by is not null;
comment on table message_channel_policy is 'r48 (2971): the channel an Admin chose for one message type (a notification code); a type without a row takes the default (urgent: both, else email). Read only while email_production_ready is on.';
alter table message_channel_policy enable row level security;
create policy admin_all on message_channel_policy for select to authenticated using (app.is_admin());
revoke all on message_channel_policy from anon, authenticated;
grant all on message_channel_policy to service_role;
create trigger audit_message_channel_policy after insert or update or delete on message_channel_policy for each row execute function app.audit_row();

-- ================================================================ 2. the rule
-- the urgent types: they keep their texts by default
create function app.channel_urgent_codes() returns text[]
language sql immutable as $$
  select array['renter_pickup_details', 'renter_pickup_soon', 'renter_late_return_first', 'renter_late_return_final',
               'renter_payment_failed', 'owner_payment_failed', 'renter_deposit_declined']
$$;

create function app.channel_default_for(p_code text) returns text
language sql immutable as $$ select case when p_code = any (app.channel_urgent_codes()) then 'both' else 'email' end $$;

-- the channel in force for a type: null while email is not ready for production (as before)
create function app.channel_policy_for(p_code text) returns text
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).email_production_ready, false) and p_code is not null
              then coalesce((select m.channel from message_channel_policy m where m.code = p_code), app.channel_default_for(p_code)) end
$$;

-- ================================================================ 3. the routing follows it
select pg_temp.patch_fn('app.notify_route()'::regprocedure,
  $o$  v_email_ok boolean;
begin$o$,
  $n$  v_email_ok boolean;
  v_pol text;
begin$n$);
select pg_temp.patch_fn('app.notify_route()'::regprocedure,
  $o$  new.channel := v_ch;
  if v_ch = 'email' or not (r ->> 'textable')::boolean or c.no_text then return new; end if;$o$,
  $n$  new.channel := v_ch;
  -- 2971: the channel of this message type (Program settings), once email is ready for production
  v_pol := app.channel_policy_for(new.code);
  if v_pol = 'email' then
    -- email only: a text only when the email cannot go (no address, or bounced or suppressed)
    if not (new.status = 'suppressed' or (new.status = 'skipped' and new.status_reason = 'no email address')) then new.channel := 'email'; return new; end if;
    v_ch := 'both';
    new.channel := 'text';
  elsif v_pol = 'text' and coalesce((r ->> 'textable')::boolean, false) then
    v_ch := 'text';
    new.channel := 'text';
  end if;
  if v_ch = 'email' or not (r ->> 'textable')::boolean or c.no_text then return new; end if;$n$);

-- an email of an email-only type that bounced, and the ones still waiting for that address: by text instead
create function app.channel_text_fallback(p_outbox uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  n notification_outbox;
  c notification_catalogue;
  w jsonb;
  r jsonb;
  v_text jsonb;
  o phone_outbox;
begin
  select * into n from notification_outbox where id = p_outbox;
  if n.id is null or n.sms_planned or n.audience not in ('renter', 'owner', 'investor') then return null; end if;
  if app.channel_policy_for(n.code) is distinct from 'email' then return null; end if;
  select * into c from notification_catalogue where code = n.code;
  if c.no_text then return null; end if;
  w := app.notify_who(n);
  r := app.notify_reach((w ->> 'user_id')::uuid, w ->> 'kind', (w ->> 'record')::uuid);
  if not coalesce((r ->> 'textable')::boolean, false) or r ->> 'phone' is null then return null; end if;
  v_text := app.sms_text_for(n.code, n.payload, n.audience, n.booking_id);
  if v_text is null then return null; end if;
  o := app.phone_outbox_put(r ->> 'phone', v_text ->> 'body', 'notify', n.booking_id, case when w ->> 'kind' = 'renter' then n.renter_id end, n.code, n.id,
         'sms:' || n.dedupe_key, greatest(now(), case when coalesce((v_text ->> 'urgent')::boolean, false) then now() else app.sms_quiet_end(now()) end));
  if o.id is null then return null; end if;
  update phone_outbox set user_id = (r ->> 'user_id')::uuid where id = o.id and user_id is null;
  update notification_outbox set sms_planned = true, channel = 'text' where id = n.id;
  return o.id;
end $$;

alter function app.outbox_record_bounce(text, text, text, text) rename to outbox_record_bounce_pre2971;
create function app.outbox_record_bounce(p_provider_id text, p_kind text, p_detail text default null, p_email text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  o notification_outbox;
  v_email text;
  v_ids uuid[];
  v_id uuid;
  x uuid;
begin
  select * into o from notification_outbox where provider_id = p_provider_id order by created_at desc limit 1;
  v_email := lower(btrim(coalesce(p_email, o.to_address)));
  select array_agg(id) into v_ids from notification_outbox where to_address = v_email and status in ('queued', 'delayed');
  v_id := app.outbox_record_bounce_pre2971(p_provider_id, p_kind, p_detail, p_email);
  if p_kind = 'bounce' then
    if o.id is not null then perform app.channel_text_fallback(o.id); end if;
    foreach x in array coalesce(v_ids, '{}'::uuid[]) loop perform app.channel_text_fallback(x); end loop;
  end if;
  return v_id;
end $$;
select pg_temp.copy_grants('app.outbox_record_bounce(text, text, text, text)'::regprocedure, 'app.outbox_record_bounce_pre2971(text, text, text, text)'::regprocedure);

-- ================================================================ 4. the list and the change
create function app.channel_policy_list(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_ready boolean := coalesce((app.settings()).email_production_ready, false);
begin
  if not coalesce(app.user_is_admin(p_by), false) then raise exception 'Only an Admin sees the channels of the messages' using errcode = '42501'; end if;
  return jsonb_build_object('production_ready', v_ready,
    'types', coalesce((
      select jsonb_agg(jsonb_build_object('code', t.code, 'label', t.label, 'audience', t.audience, 'urgent', t.code = any (app.channel_urgent_codes()),
               'channel', coalesce(m.channel, app.channel_default_for(t.code)), 'chosen', m.channel is not null, 'default', app.channel_default_for(t.code),
               'texts_30d', coalesce(k.n, 0), 'editable', true)
             order by coalesce(k.n, 0) desc, t.label)
        from (select s.code, s.label, c.audience from sms_templates s join notification_catalogue c on c.code = s.code
               where c.audience in ('renter', 'owner', 'investor') and not c.no_text) t
        left join message_channel_policy m on m.code = t.code
        left join (select coalesce(sms_kind, kind) as code, count(*) as n from phone_outbox
                    where status = 'sent' and sent_at > now() - interval '30 days' group by 1) k on k.code = t.code), '[]'::jsonb),
    'fixed', coalesce((
      select jsonb_agg(jsonb_build_object('code', k.code, 'texts_30d', k.n) order by k.n desc, k.code)
        from (select coalesce(sms_kind, kind) as code, count(*) as n from phone_outbox
               where status = 'sent' and sent_at > now() - interval '30 days' group by 1) k
       where not exists (select 1 from sms_templates s join notification_catalogue c on c.code = s.code
                          where s.code = k.code and c.audience in ('renter', 'owner', 'investor') and not c.no_text)), '[]'::jsonb));
end $$;

-- p: {code, channel: text | email | both | null (back to the default)}
create function app.channel_policy_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := nullif(btrim(coalesce(p ->> 'code', '')), '');
  v_ch text := nullif(btrim(coalesce(p ->> 'channel', '')), '');
  v_old text;
begin
  if not coalesce(app.user_is_admin(p_by), false) then raise exception 'Only an Admin sets the channel of a message' using errcode = '42501'; end if;
  if v_code is null or not exists (select 1 from sms_templates s join notification_catalogue c on c.code = s.code
                                    where s.code = v_code and c.audience in ('renter', 'owner', 'investor') and not c.no_text) then
    raise exception 'Choose a message type that can go by text' using errcode = '22023';
  end if;
  if v_ch is not null and v_ch not in ('text', 'email', 'both') then raise exception 'The channel is text, email or both' using errcode = '22023'; end if;
  select channel into v_old from message_channel_policy where code = v_code;
  if v_ch is null or v_ch = app.channel_default_for(v_code) then
    delete from message_channel_policy where code = v_code;
  else
    insert into message_channel_policy (code, channel, updated_by) values (v_code, v_ch, p_by)
    on conflict (code) do update set channel = excluded.channel, updated_by = excluded.updated_by, updated_at = now();
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'channel_policy_set', 'message_channel_policy', v_code, jsonb_build_object('channel', coalesce(v_old, app.channel_default_for(v_code))),
          jsonb_build_object('channel', coalesce(v_ch, app.channel_default_for(v_code))));
  return jsonb_build_object('code', v_code, 'channel', coalesce(v_ch, app.channel_default_for(v_code)), 'chosen', v_ch is not null and v_ch <> app.channel_default_for(v_code));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2971;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'channel_policy' then
    perform app.door_begin(p_user, p_aal);
    return app.channel_policy_list(p_user);
  end if;
  if p_call = 'admin_do' and p_name = 'channel_policy_set' then
    perform app.door_begin(p_user, p_aal);
    return app.channel_policy_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2971(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2971(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['channel_urgent_codes', 'channel_default_for', 'channel_policy_for', 'channel_text_fallback',
             'outbox_record_bounce_pre2971', 'channel_policy_list', 'channel_policy_set', 'door_pre2971'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
