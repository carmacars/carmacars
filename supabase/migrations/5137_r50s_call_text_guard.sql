-- 5137 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "salespeople cannot send phone
-- numbers by text through the main line (block and tell them why), and every time a salesperson says a phone number on a
-- call, or swears or uses other risky words (off-platform payment, personal number, cash only, threats, discrimination),
-- the call is flagged for Admin with the transcript line".
--
-- 1. Texts: a text a salesperson sends from the business line (va_do or field_do phone_compose, phone_reply) that holds a
--    phone number (ten digits, written with or without spaces, dashes, dots or brackets, or spelled out) is refused before
--    it is queued, with the reason: customers keep their conversation on the CarmaCars line, so no number is passed by
--    text. The attempt is kept as a flag for Admin (source text). Admins and staff without Sales are not limited. Every
--    other path that queues a salesperson's text (phone_outbox, kind staff) refuses it too. Dates, times, prices and
--    booking numbers are not phone numbers.
-- 2. Calls: when a call's transcript arrives (Quo's dialogue, or the site's own call transcript, 1880) and the staff member
--    on the call holds the Sales function, each line said by our side (the whole call when the transcript does not say who
--    spoke) is checked: a phone number, and the words of call_flag_words (swearing, off-platform payment, personal number,
--    cash only, threats, discrimination; an Admin adds or switches off words on Call flags). Each hit is a call_flags row
--    with the line, the category, the call and the person; the Admins get one alert a call (call_flagged) with the first line.
-- 3. Admin > Call flags (admin_read call_flags): the flags, newest first, unreviewed first, with the line and a link to the
--    call's conversation; Mark reviewed with a note (admin_do call_flag_review); the word list (admin_do call_flag_word).
-- SCHEMA_MARKER is not changed. New tables: row-level security, admin_all, the audit trigger. No applied migration is
-- edited: app.door is wrapped (_pre5137).
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

create table call_flag_words (
  id          uuid primary key default gen_random_uuid(),
  phrase      text not null unique check (phrase = lower(btrim(phrase)) and length(phrase) between 2 and 60),
  category    text not null check (category in ('swearing', 'off_platform_payment', 'personal_number', 'cash_only', 'threat', 'discrimination')),
  active      boolean not null default true,
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table call_flag_words is 'Words and phrases that flag a salesperson''s call for Admin (5137), by category. An Admin adds or switches them off.';
create trigger call_flag_words_updated before update on call_flag_words for each row execute function app.set_updated_at();
create trigger audit_call_flag_words after insert or update or delete on call_flag_words for each row execute function app.audit_row();
alter table call_flag_words enable row level security;
create policy admin_all on call_flag_words for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on call_flag_words from public, anon, authenticated;
grant all on call_flag_words to service_role;

insert into call_flag_words (phrase, category) values
  ('fuck', 'swearing'), ('fucking', 'swearing'), ('shit', 'swearing'), ('bitch', 'swearing'), ('asshole', 'swearing'), ('bastard', 'swearing'),
  ('dickhead', 'swearing'), ('motherfucker', 'swearing'), ('bullshit', 'swearing'), ('cunt', 'swearing'), ('piss off', 'swearing'),
  ('e-transfer me directly', 'off_platform_payment'), ('send it to me directly', 'off_platform_payment'), ('pay me directly', 'off_platform_payment'),
  ('pay me personally', 'off_platform_payment'), ('my personal account', 'off_platform_payment'), ('outside the site', 'off_platform_payment'),
  ('off the books', 'off_platform_payment'), ('venmo', 'off_platform_payment'), ('zelle', 'off_platform_payment'), ('cash app', 'off_platform_payment'),
  ('western union', 'off_platform_payment'), ('my personal number', 'personal_number'), ('my cell number', 'personal_number'),
  ('my own number', 'personal_number'), ('call me on my cell', 'personal_number'), ('text me on my', 'personal_number'), ('my whatsapp', 'personal_number'),
  ('cash only', 'cash_only'), ('only cash', 'cash_only'), ('cash under the table', 'cash_only'),
  ('i will kill', 'threat'), ('i''ll kill', 'threat'), ('you will regret', 'threat'), ('i know where you live', 'threat'), ('i will hurt', 'threat'),
  ('we don''t rent to your kind', 'discrimination'), ('your kind', 'discrimination'), ('people like you', 'discrimination'), ('go back to your country', 'discrimination')
on conflict (phrase) do nothing;

create table call_flags (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid references phone_activity (id) on delete cascade,
  staff_id     uuid references users (id) on delete set null,
  source       text not null check (source in ('call', 'text')),
  category     text not null check (category in ('phone_number', 'swearing', 'off_platform_payment', 'personal_number', 'cash_only', 'threat', 'discrimination')),
  phrase       text,
  line         text not null check (length(line) <= 600),
  speaker      text not null default 'us' check (speaker in ('us', 'unknown')),
  blocked      boolean not null default false,
  reviewed_at  timestamptz,
  reviewed_by  uuid references users (id),
  review_note  text check (review_note is null or length(review_note) <= 300),
  created_at   timestamptz not null default now()
);
comment on table call_flags is 'A salesperson''s call line or blocked text flagged for Admin (5137): a phone number, swearing or other risky words, with the line.';
create unique index call_flags_one on call_flags (activity_id, category, md5(line)) where activity_id is not null;
create index call_flags_staff_idx on call_flags (staff_id, created_at);
create index call_flags_open_idx on call_flags (created_at desc) where reviewed_at is null;
create trigger audit_call_flags after insert or update or delete on call_flags for each row execute function app.audit_row();
alter table call_flags enable row level security;
create policy admin_all on call_flags for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on call_flags from public, anon, authenticated;
grant all on call_flags to service_role;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('call_flagged', 'A sales call or text was flagged', 'Sales', '{admin}', 'urgent', 'alerts', true, false,
   '5137: a salesperson said a phone number or risky words on a call, or tried to text a phone number; the line is on Call flags.', 54, 'staff_system')
on conflict (rule) do nothing;

-- ================================================================ the checks
-- Spoken digits become digits, and the separators between digits go, so "647 555-0101" and "six four seven ..." read alike.
create function app.digits_spoken(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select regexp_replace(
           regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
             lower(coalesce(p, '')), '\mzero\M', '0', 'g'), '\moh\M', '0', 'g'), '\mone\M', '1', 'g'), '\mtwo\M', '2', 'g'), '\mthree\M', '3', 'g'), '\mfour\M', '4', 'g'),
             '\mfive\M', '5', 'g'), '\msix\M', '6', 'g'), '\mseven\M', '7', 'g'), '\meight\M', '8', 'g'), '\mnine\M', '9', 'g'),
           '(\d)[\s.,()+-]+(?=\d)', '\1', 'g')
$$;

-- A phone number: a run of 10 or 11 digits (spaces, dashes, dots and brackets between them allowed, or spoken). Dates,
-- times, prices and booking numbers are taken out first, so "2026-11-27 10:30", "$1,250.00" and "CC-10673" are not numbers.
create function app.phone_text_clean(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(lower(coalesce(p, '')),
           '\m[a-z]{1,4}-\d+\M', ' ', 'g'),                                         -- booking and other references: CC-10673
           '\$\s*\d[\d,]*(\.\d+)?', ' ', 'g'),                                     -- prices: $1,250.00
           '\m\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\M|\m\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}\M', ' ', 'g'),  -- dates
           '\m\d{1,2}:\d{2}(:\d{2})?(\s*[ap]\.?m\.?)?', ' ', 'g'),               -- times
           '\m\d[\d,]*\.\d+\M', ' ', 'g')                                         -- decimals
$$;

create function app.has_phone_number(p text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select app.digits_spoken(app.phone_text_clean(p)) ~ '(^|\D)1?\d{10}(\D|$)'
$$;

-- the flags of one line: (category, phrase)
create function app.line_flags(p_line text) returns table (category text, phrase text)
language sql stable security definer set search_path = public, app, pg_temp as $$
  select 'phone_number', null::text where app.has_phone_number(p_line)
  union all
  select w.category, w.phrase from call_flag_words w
   where w.active and lower(coalesce(p_line, '')) ~ ('(^|[^a-z])' || regexp_replace(w.phrase, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '([^a-z]|$)')
$$;

-- the staff member on a call
create function app.call_staff(a phone_activity) returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(a.staff_user_id, (select oc.staff_user_id from outbound_calls oc where oc.activity_id = a.id order by oc.created_at desc limit 1), a.sent_by)
$$;

create function app.call_flag_scan(p_activity uuid) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a phone_activity;
  v_staff uuid;
  e jsonb;
  v_line text;
  f record;
  v_first text;
  n integer := 0;
  k integer;
begin
  select * into a from phone_activity where id = p_activity;
  if a.id is null or a.kind <> 'call' or jsonb_typeof(a.transcript) <> 'array' then return 0; end if;
  v_staff := app.call_staff(a);
  if v_staff is null or not app.user_va_has_sales(v_staff) or app.user_is_admin(v_staff) then return 0; end if;
  for e in select x from jsonb_array_elements(a.transcript) x where x ->> 'who' in ('us', 'call') loop
    for v_line in select btrim(s) from regexp_split_to_table(coalesce(e ->> 'text', ''), case when e ->> 'who' = 'call' then '(?<=[.!?])\s+' else '\n' end) s
                   where btrim(s) <> '' loop
      for f in select * from app.line_flags(v_line) loop
        insert into call_flags (activity_id, staff_id, source, category, phrase, line, speaker)
        values (a.id, v_staff, 'call', f.category, f.phrase, left(v_line, 600), case when e ->> 'who' = 'us' then 'us' else 'unknown' end)
        on conflict (activity_id, category, md5(line)) where activity_id is not null do nothing;
        get diagnostics k = row_count;
        if k > 0 then n := n + 1; v_first := coalesce(v_first, left(v_line, 200)); end if;
      end loop;
    end loop;
  end loop;
  if n > 0 then
    begin
      perform app.staff_alert('call_flagged', 'phone_activity', a.id, 'call',
        left(format('%s''s call was flagged (%s)', coalesce((select u.full_name from users u where u.id = v_staff), 'A salesperson'), n || case when n = 1 then ' line' else ' lines' end), 140),
        left('"' || v_first || '"', 240), jsonb_build_object('path_admin', '/admin/call-flags'));
    exception when others then raise warning 'call flag alert not sent for %: %', a.id, sqlerrm;
    end;
  end if;
  return n;
end $$;

create function app.call_flag_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.kind = 'call' and new.transcript is not null and (tg_op = 'INSERT' or new.transcript is distinct from old.transcript) then
    perform app.call_flag_scan(new.id);
  end if;
  return null;
exception when others then
  raise warning 'call flag scan failed for %: %', new.id, sqlerrm;
  return null;
end $$;
create trigger phone_activity_zz_call_flags after insert or update of transcript on phone_activity
  for each row execute function app.call_flag_trg();

-- a salesperson's text with a phone number: kept as a flag, then refused
create function app.text_phone_guard(p_user uuid, p_body text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_user is null or not app.user_va_has_sales(p_user) or app.user_is_admin(p_user) or not app.has_phone_number(p_body) then return; end if;
  insert into call_flags (staff_id, source, category, line, blocked) values (p_user, 'text', 'phone_number', left(btrim(p_body), 600), true);
  begin
    perform app.staff_alert('call_flagged', 'user', p_user, 'text:' || md5(p_body),
      left(format('%s tried to text a phone number (blocked)', coalesce((select u.full_name from users u where u.id = p_user), 'A salesperson')), 140),
      left('"' || btrim(p_body) || '"', 240), jsonb_build_object('path_admin', '/admin/call-flags'));
  exception when others then raise warning 'text flag alert not sent: %', sqlerrm;
  end;
end $$;

-- Every other way a salesperson's text is queued (quick texts, the lead and booking pages, templates): the outbox refuses a
-- staff text with a phone number from a salesperson, with the same reason (compose and reply above answer it on screen
-- and keep the flag).
create function app.phone_outbox_guard() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.kind = 'staff' and new.sent_by is not null and app.user_va_has_sales(new.sent_by) and not app.user_is_admin(new.sent_by)
     and app.has_phone_number(new.body) then
    raise exception 'Not sent: phone numbers are not sent by text on the CarmaCars line. Call the customer through the site, or ask an Admin.'
      using errcode = '23514';
  end if;
  return new;
end $$;
create trigger phone_outbox_phone_guard before insert on phone_outbox for each row execute function app.phone_outbox_guard();

-- ================================================================ Admin
create function app.call_flags_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_all boolean := coalesce((p ->> 'all')::boolean, false);
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('open', (select count(*) from call_flags where reviewed_at is null),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'source', f.source, 'category', f.category, 'phrase', f.phrase, 'line', f.line, 'speaker', f.speaker,
               'blocked', f.blocked, 'staff', coalesce(u.full_name, u.email), 'at', coalesce(a.started_at, f.created_at), 'thread_id', a.thread_id, 'activity_id', f.activity_id,
               'reviewed_at', f.reviewed_at, 'review_note', f.review_note, 'reviewed_by', (select coalesce(r.full_name, r.email) from users r where r.id = f.reviewed_by))
             order by (f.reviewed_at is null) desc, f.created_at desc)
             from (select * from call_flags x where v_all or x.reviewed_at is null or x.reviewed_at > now() - interval '7 days' order by x.created_at desc limit 300) f
             left join users u on u.id = f.staff_id left join phone_activity a on a.id = f.activity_id), '[]'::jsonb),
    'words', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'phrase', w.phrase, 'category', w.category, 'active', w.active) order by w.category, w.phrase) from call_flag_words w), '[]'::jsonb));
end $$;

-- p: {flag, note}
create function app.call_flag_review(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid := nullif(p ->> 'flag', '')::uuid;
begin
  perform app.assert_admin(p_by);
  update call_flags set reviewed_at = now(), reviewed_by = p_by, review_note = nullif(left(btrim(coalesce(p ->> 'note', '')), 300), '')
   where id = v_id and reviewed_at is null;
  if not found then raise exception 'That flag is reviewed already or not there' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'flag', v_id);
end $$;

-- p: {phrase, category} adds (or switches on) a word; {id, active} switches one on or off
create function app.call_flag_word(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_phrase text := lower(btrim(coalesce(p ->> 'phrase', '')));
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if nullif(p ->> 'id', '') is not null then
    update call_flag_words set active = coalesce((p ->> 'active')::boolean, false) where id = (p ->> 'id')::uuid returning id into v_id;
    if v_id is null then raise exception 'Word not found' using errcode = 'P0002'; end if;
  else
    if length(v_phrase) < 2 or length(v_phrase) > 60 then raise exception 'Type a word or phrase of 2 to 60 characters' using errcode = '22023'; end if;
    insert into call_flag_words (phrase, category, created_by) values (v_phrase, p ->> 'category', p_by)
    on conflict (phrase) do update set category = excluded.category, active = true
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5137;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call in ('va_do', 'field_do', 'ops_do') and p_name in ('phone_compose', 'phone_reply') and app.has_phone_number(p_ ->> 'body') then
    perform app.door_begin(p_user, p_aal);
    if app.user_va_has_sales(p_user) and not app.user_is_admin(p_user) then
      perform app.text_phone_guard(p_user, p_ ->> 'body');
      -- the flag is kept: the refusal is answered, not raised, so this transaction commits
      return jsonb_build_object('ok', false, 'blocked', true,
        'error', 'Not sent: phone numbers are not sent by text on the CarmaCars line. Customers keep their conversation with us here: call them through the site, or ask an Admin.');
    end if;
  end if;
  if p_call = 'admin_read' and p_name = 'call_flags' then
    perform app.door_begin(p_user, p_aal);
    return app.call_flags_admin(p_user, p_);
  end if;
  if p_call = 'admin_do' and p_name in ('call_flag_review', 'call_flag_word') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'call_flag_review' then return app.call_flag_review(p_user, p_); end if;
    return app.call_flag_word(p_user, p_);
  end if;
  return app.door_pre5137(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5137(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.digits_spoken(text), app.phone_text_clean(text), app.phone_outbox_guard(), app.has_phone_number(text), app.line_flags(text), app.call_staff(phone_activity), app.call_flag_scan(uuid),
  app.call_flag_trg(), app.text_phone_guard(uuid, text), app.call_flags_admin(uuid, jsonb), app.call_flag_review(uuid, jsonb), app.call_flag_word(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.digits_spoken(text), app.phone_text_clean(text), app.phone_outbox_guard(), app.has_phone_number(text), app.line_flags(text), app.call_staff(phone_activity), app.call_flag_scan(uuid),
  app.call_flag_trg(), app.text_phone_guard(uuid, text), app.call_flags_admin(uuid, jsonb), app.call_flag_review(uuid, jsonb), app.call_flag_word(uuid, jsonb) to service_role;
