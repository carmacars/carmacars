-- 0955: two renter records of one person merged by themselves (release 35, part Y; docs/changes/2026-11-08-r35-account-merge.md).
-- The owner, November 8 (item 11): when two renter records or accounts are the same person (the same verified phone, or the
-- same name, date of birth and phone), merge them automatically into the record with the most history; the person then
-- signs in with ANY of their emails, or with their phone by a texted code. Weak matches (a name alone) stay a staff task.
-- Audited and reversible by an Admin; bookings, licences, cards, payments, documents and messages move; one short note to
-- the renter, "your accounts are now one". Run once for today's duplicates.
--
-- 1. Every merge, by staff (Merge into this record, 0148) or automatic, goes through app.renter_merge, now a wrapper of the
--    0148 merge (renter_merge_pre0955): before it moves anything it records, in renter_merges, each row it will move (by its
--    key), the account holder drivers it demotes, a reward account it removes (one account per renter: the kept one stays,
--    the ledger moves), both records and both sign-ins as they were. After it: when both records had a sign-in, the other
--    sign-in's email becomes a sign-in alias of the kept account (user_email_aliases), the other account points at it
--    (users.merged_into), and a verified phone moves to the kept account when it has none. The "check they are the same
--    person" tasks of the pair close.
-- 2. Strong match (app.rm_strength): the same verified phone (a sign-in verified it by code) on both records, or the same
--    name, date of birth and phone. Never a phone found on three records or more (a shared or office number), never a
--    blocked record, a test address or a staff account. The kept record is the one with more bookings, then more payments,
--    then a confirmed sign-in, then the older one (app.rm_keep).
-- 3. app.renter_auto_merge runs with the 15-minute job (app.job_capture) and once here for today's duplicates. A merge that
--    fails (a row the database refuses to move) becomes the usual staff task instead.
-- 4. Undo (Admin, renter_merge_undo): every moved row goes back, both records and both sign-ins are as they were, the
--    aliases go. Both records' change history says so.
-- 5. Sign-in: public.server_sign_in_alias (the server only) answers the kept account for an alias email or a merged account.
-- 6. The renter gets one note, renter_accounts_merged (email), naming the addresses they can sign in with.
-- No applied migration is edited; app.renter_merge, app.door and app.job_capture are wrapped.
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
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0955: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. tables
alter table users add column if not exists merged_into uuid references users (id);
comment on column users.merged_into is 'Since 0955: this sign-in belongs to a person whose renter records were merged; they sign in to that account (its email alias is in user_email_aliases).';

create table if not exists user_email_aliases (
  email        text primary key check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  user_id      uuid not null references users (id) on delete cascade,
  from_user_id uuid references users (id) on delete set null,
  merge_id     uuid,
  created_at   timestamptz not null default now()
);
comment on table user_email_aliases is 'Sign-in aliases (0955): an email of a merged sign-in that signs in to the kept account.';
create index if not exists user_email_aliases_user_idx on user_email_aliases (user_id);
alter table user_email_aliases enable row level security;

-- no foreign key to renters on purpose: the 0148 merge moves every reference to the merged record
create table if not exists renter_merges (
  id             uuid primary key default gen_random_uuid(),
  keep_id        uuid not null,
  merged_id      uuid not null,
  auto           boolean not null default false,
  strength       text check (strength in ('strong', 'weak')),
  reason         text,
  by_user        uuid references users (id),
  moved          jsonb not null default '[]'::jsonb,
  holders        uuid[] not null default '{}',
  removed        jsonb not null default '[]'::jsonb,
  keep_before    jsonb not null,
  merged_before  jsonb not null,
  users_before   jsonb not null default '{}'::jsonb,
  alias_emails   text[] not null default '{}',
  created_at     timestamptz not null default now(),
  undone_at      timestamptz,
  undone_by      uuid references users (id),
  undo_reason    text
);
comment on table renter_merges is 'Renter merges (0955): each merge, by staff or automatic, with every row moved, so an Admin can undo it.';
create index if not exists renter_merges_keep_idx on renter_merges (keep_id, created_at);
create index if not exists renter_merges_merged_idx on renter_merges (merged_id);
alter table renter_merges enable row level security;

-- the system merges: the 0148 merge accepts no person for an automatic one
select pg_temp.patch_fn('app.renter_merge(uuid, jsonb)'::regprocedure,
  'if not app.may_edit_renter(p_by) then',
  'if not (app.may_edit_renter(p_by) or current_setting(''app.renter_merge_system'', true) = ''on'') then');
alter function app.renter_merge(uuid, jsonb) rename to renter_merge_pre0955;

-- ================================================================ 2. strength and which to keep
create or replace function app.rm_vphone(r renters) returns text
language sql stable security definer set search_path = public, app as $$
  select u.phone from users u where u.id = r.user_id and u.phone_verified_at is not null
$$;

-- a phone on three records or more is not one person's
create or replace function app.rm_phone_personal(p_phone text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_phone is not null and (select count(*) from renters x where x.merged_into is null and app.phone_e164(x.mobile) = p_phone) < 3
$$;

create or replace function app.rm_strength(a renters, b renters) returns text
language sql stable security definer set search_path = public, app as $$
  with v as (select app.rm_vphone(a) va, app.rm_vphone(b) vb, app.phone_e164(a.mobile) ma, app.phone_e164(b.mobile) mb)
  select case
    when a.id = b.id then null
    when ((v.va is not null and (v.va = v.vb or v.va = v.mb)) or (v.vb is not null and v.vb = v.ma))
         and app.rm_phone_personal(coalesce(v.va, v.vb)) then 'strong'
    when lower(btrim(coalesce(a.legal_name, ''))) <> '' and lower(btrim(a.legal_name)) = lower(btrim(b.legal_name))
         and a.date_of_birth is not null and a.date_of_birth = b.date_of_birth and v.ma is not null and v.ma = v.mb and app.rm_phone_personal(v.ma) then 'strong'
    when lower(btrim(coalesce(a.legal_name, ''))) <> '' and lower(btrim(a.legal_name)) = lower(btrim(b.legal_name)) then 'weak'
    else null end
    from v
$$;

-- may these two be merged without a person looking: neither blocked nor merged, no test address, no staff account
create or replace function app.rm_auto_ok(a renters, b renters) returns boolean
language sql stable security definer set search_path = public, app as $$
  select a.merged_into is null and b.merged_into is null and not a.is_blocked and not b.is_blocked
     and not app.email_is_test(coalesce(a.email, (select u.email from users u where u.id = a.user_id)))
     and not app.email_is_test(coalesce(b.email, (select u.email from users u where u.id = b.user_id)))
     and not exists (select 1 from user_roles r where r.user_id in (a.user_id, b.user_id) and r.role::text in ('admin', 'va', 'field', 'owner', 'investor'))
$$;

-- the record with more history first: bookings, payments, a confirmed sign-in, then the older
create or replace function app.rm_keep(a renters, b renters) returns uuid
language sql stable security definer set search_path = public, app as $$
  select x.id from (values (a.id, a.created_at, a.user_id), (b.id, b.created_at, b.user_id)) x(id, created_at, user_id)
   order by (select count(*) from bookings bk where bk.renter_id = x.id) desc, (select count(*) from payments p where p.renter_id = x.id) desc,
            (x.user_id is not null and app.account_has_confirmed_sign_in(x.user_id)) desc, x.created_at asc, x.id
   limit 1
$$;

-- ================================================================ 3. the merge, recorded
-- p: {keep, merge, reason}; p_auto and p_strength for the automatic one (p_by null)
create or replace function app.renter_merge_do(p_by uuid, p jsonb, p_auto boolean default false, p_strength text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  k renters;
  m renters;
  ku users;
  mu users;
  t record;
  v_pk text;
  v_rows jsonb;
  v_moved jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_holders uuid[];
  v_users jsonb;
  v_res jsonb;
  v_id uuid := gen_random_uuid();
  v_kuser uuid;
  v_aliases text[] := '{}';
  v_emails text;
begin
  if not p_auto and not app.may_edit_renter(p_by) then raise exception 'Customer service, sales and Admins merge renters' using errcode = '42501'; end if;
  select * into k from renters where id = (p ->> 'keep')::uuid for update;
  select * into m from renters where id = (p ->> 'merge')::uuid for update;
  if k.id is null or m.id is null then raise exception 'Choose the two records of the renter' using errcode = '22023'; end if;
  if k.id = m.id then raise exception 'That is the same record' using errcode = '22023'; end if;
  if m.merged_into is not null then raise exception 'That record was already merged' using errcode = '23514'; end if;
  if k.merged_into is not null then raise exception 'Keep the record it was merged into instead' using errcode = '23514'; end if;
  select * into ku from users where id = k.user_id;
  select * into mu from users where id = m.user_id;
  v_users := jsonb_build_object('keep', case when ku.id is not null then jsonb_build_object('id', ku.id, 'phone', ku.phone, 'phone_verified_at', ku.phone_verified_at, 'merged_into', ku.merged_into) end,
                                'merged', case when mu.id is not null then jsonb_build_object('id', mu.id, 'phone', mu.phone, 'phone_verified_at', mu.phone_verified_at, 'merged_into', mu.merged_into) end);
  -- the rows the 0148 merge will move, by their key
  for t in select c.conrelid, c.conrelid::regclass::text as tbl, a.attname as col
             from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
            where c.confrelid = 'renters'::regclass and c.contype = 'f' and c.conrelid <> 'renters'::regclass
              and c.conrelid::regclass::text not in ('renter_edits', 'data_access_log')
  loop
    select 'jsonb_build_object(' || string_agg(format('%L, x.%I', att.attname, att.attname), ', ' order by k2.ord) || ')' into v_pk
      from pg_constraint pc cross join lateral unnest(pc.conkey) with ordinality k2(n, ord) join pg_attribute att on att.attrelid = pc.conrelid and att.attnum = k2.n
     where pc.conrelid = t.conrelid and pc.contype = 'p';
    execute format('select jsonb_agg(%s) from %s x where x.%I = $1', coalesce(v_pk, format('to_jsonb(x) - %L', t.col)), t.tbl, t.col) into v_rows using m.id;
    if v_rows is not null then v_moved := v_moved || jsonb_build_array(jsonb_build_object('t', t.tbl, 'c', t.col, 'rows', v_rows)); end if;
  end loop;
  select coalesce(array_agg(d.id), '{}') into v_holders from drivers d where d.renter_id = m.id and d.is_account_holder
     and exists (select 1 from drivers d2 where d2.renter_id = k.id and d2.is_account_holder);
  -- one reward account a renter: the kept one stays (the points ledger moves)
  if exists (select 1 from reward_accounts ra where ra.renter_id = k.id) then
    select coalesce(jsonb_agg(to_jsonb(ra)), '[]'::jsonb) into v_removed from reward_accounts ra where ra.renter_id = m.id;
    delete from reward_accounts where renter_id = m.id;
    v_moved := (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(v_moved) e where e ->> 't' <> 'reward_accounts');
  end if;
  perform set_config('app.renter_merge_system', case when p_auto then 'on' else '' end, true);
  v_res := app.renter_merge_pre0955(p_by, p);
  perform set_config('app.renter_merge_system', '', true);
  -- the sign-ins: the other one's email signs in to the kept account; a verified phone moves to it when it has none
  select user_id into v_kuser from renters where id = k.id;
  if mu.id is not null and v_kuser is not null and mu.id <> v_kuser then
    if nullif(btrim(coalesce(mu.email, '')), '') is not null and lower(btrim(mu.email)) is distinct from lower((select u.email from users u where u.id = v_kuser)) then
      insert into user_email_aliases (email, user_id, from_user_id, merge_id) values (lower(btrim(mu.email)), v_kuser, mu.id, v_id)
      on conflict (email) do update set user_id = excluded.user_id, from_user_id = excluded.from_user_id, merge_id = excluded.merge_id, created_at = now();
      v_aliases := array[lower(btrim(mu.email))];
    end if;
    update user_email_aliases set user_id = v_kuser where user_id = mu.id;
    update users set merged_into = v_kuser where id = mu.id;
    if mu.phone_verified_at is not null and not exists (select 1 from users u where u.id = v_kuser and u.phone_verified_at is not null) then
      update users set phone_verified_at = null where id = mu.id;
      update users set phone = mu.phone, phone_verified_at = mu.phone_verified_at where id = v_kuser;
    end if;
  end if;
  insert into renter_merges (id, keep_id, merged_id, auto, strength, reason, by_user, moved, holders, removed, keep_before, merged_before, users_before, alias_emails)
  values (v_id, k.id, m.id, p_auto, p_strength, nullif(btrim(coalesce(p ->> 'reason', '')), ''), p_by, v_moved, v_holders, v_removed, to_jsonb(k), to_jsonb(m), v_users, v_aliases);
  -- the "check they are the same person" tasks of the pair are answered
  update tasks set status = 'done', completed_at = now()
   where task_type in ('account_phone_review', 'account_link_review') and status in ('open', 'in_progress', 'waiting')
     and (related_id in (k.id, m.id) or renter_id = m.id);
  -- one note to the renter
  v_emails := (select string_agg(e, ' or ' order by e) from (select distinct lower(x) e from unnest(array[(select u.email from users u where u.id = v_kuser), k.email, m.email, mu.email]) x
                                                              where nullif(btrim(coalesce(x, '')), '') is not null) z);
  if v_emails is not null then
    perform app.ntf_emit('renter_accounts_merged', 'renter', k.id, 'merge:' || v_id,
      jsonb_build_object('renter_id', k.id, 'first_name', split_part(coalesce(nullif(btrim(k.legal_name), ''), nullif(btrim(m.legal_name), ''), ''), ' ', 1),
                         'sign_in_emails', v_emails));
  end if;
  return coalesce(v_res, '{}'::jsonb) || jsonb_build_object('merge_id', v_id, 'aliases', to_jsonb(v_aliases));
end $$;

-- the staff path keeps its name and its answer (Merge into this record)
create function app.renter_merge(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.renter_merge_do(p_by, p, false, null);
end $$;
select pg_temp.copy_grants('app.renter_merge(uuid, jsonb)'::regprocedure, 'app.renter_merge_pre0955(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the automatic merge
create or replace function app.renter_auto_merge(p_now timestamptz default now(), p_limit integer default 200) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  pr record;
  a renters;
  b renters;
  v_keep uuid;
  n integer := 0;
begin
  for pr in
    with r0 as (
      select rn.id, app.phone_e164(rn.mobile) mob, app.rm_vphone(rn) vph from renters rn where rn.merged_into is null and not rn.is_blocked
    ), shared as (
      -- a number on three records or more is not one person's (an office or a shared phone): never a pair
      select x.mob from r0 x where x.mob is not null group by x.mob having count(*) >= 3
    ), r as (
      select r0.id, case when r0.mob in (select mob from shared) then null else r0.mob end mob,
             case when r0.vph in (select mob from shared) then null else r0.vph end vph from r0
    )
    select distinct least(x.a, x.b) a, greatest(x.a, x.b) b from (
      select r1.id a, r2.id b from r r1 join r r2 on r2.vph = r1.vph and r1.id <> r2.id where r1.vph is not null
      union all select r1.id, r2.id from r r1 join r r2 on r2.mob = r1.vph and r1.id <> r2.id where r1.vph is not null
      union all select r1.id, r2.id from r r1 join r r2 on r2.mob = r1.mob and r1.id <> r2.id where r1.mob is not null
    ) x
    order by 1, 2
    limit p_limit * 5
  loop
    exit when n >= p_limit;
    select * into a from renters where id = pr.a;
    select * into b from renters where id = pr.b;
    continue when a.id is null or b.id is null or a.merged_into is not null or b.merged_into is not null;
    continue when app.rm_strength(a, b) is distinct from 'strong' or not app.rm_auto_ok(a, b);
    v_keep := app.rm_keep(a, b);
    begin
      perform app.renter_merge_do(null, jsonb_build_object('keep', v_keep, 'merge', case when v_keep = a.id then b.id else a.id end,
        'reason', 'The same person (the same verified phone, or the same name, date of birth and phone): merged automatically'), true, 'strong');
      n := n + 1;
    exception when others then
      perform app.raise_task(p_type => 'account_phone_review', p_title => format('Two records of %s could not be merged automatically', coalesce(nullif(btrim(a.legal_name), ''), 'a renter')),
        p_detail => format('The records %s and %s look like the same person, but the merge stopped: %s. Check them and use Merge into this record.', a.id, b.id, left(sqlerrm, 200)),
        p_renter => v_keep, p_related_table => 'renters', p_related_id => v_keep, p_dedupe => format('auto_merge_failed:%s:%s', a.id, b.id));
    end;
  end loop;
  return n;
end $$;

alter function app.job_capture(timestamptz) rename to job_capture_pre0955;
create function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_capture_pre0955(p_now);
  n integer := 0;
begin
  begin
    n := app.renter_auto_merge(p_now, 50);
  exception when others then
    raise warning 'automatic renter merge failed: %', sqlerrm;
  end;
  return v || case when n > 0 then format(', renters merged %s', n) else '' end;
end $$;
select pg_temp.copy_grants('app.job_capture(timestamptz)'::regprocedure, 'app.job_capture_pre0955(timestamptz)'::regprocedure);

-- ================================================================ 5. undo (Admin)
-- p: {merge, reason}
create or replace function app.renter_merge_undo(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g renter_merges;
  e jsonb;
  key jsonb;
  v_set text;
begin
  perform app.assert_admin(p_by);
  select * into g from renter_merges where id = (p ->> 'merge')::uuid for update;
  if g.id is null then raise exception 'Merge not found' using errcode = 'P0002'; end if;
  if g.undone_at is not null then raise exception 'This merge was undone already' using errcode = '23514'; end if;
  if exists (select 1 from renter_merges x where x.merged_id = g.keep_id and x.undone_at is null and x.created_at > g.created_at)
     or exists (select 1 from renter_merges x where x.keep_id = g.keep_id and x.undone_at is null and x.created_at > g.created_at) then
    raise exception 'A later merge of this record comes first: undo it before this one' using errcode = '23514';
  end if;
  -- the sign-ins as they were (the kept record lets go of a sign-in it took first: one sign-in a record)
  delete from user_email_aliases where merge_id = g.id;
  select string_agg(format('%I = b.%I', attname, attname), ', ') into v_set
    from pg_attribute where attrelid = 'renters'::regclass and attnum > 0 and not attisdropped and attname <> 'id' and attgenerated = '';
  execute format('update renters r set %s from jsonb_populate_record(null::renters, $1) b where r.id = b.id', v_set) using g.keep_before;
  execute format('update renters r set %s from jsonb_populate_record(null::renters, $1) b where r.id = b.id', v_set) using g.merged_before;
  if g.users_before -> 'merged' ->> 'id' is not null then
    update users set merged_into = nullif(g.users_before -> 'merged' ->> 'merged_into', '')::uuid where id = (g.users_before -> 'merged' ->> 'id')::uuid;
    if g.users_before -> 'keep' ->> 'id' is not null then
      update users set phone = g.users_before -> 'keep' ->> 'phone', phone_verified_at = (g.users_before -> 'keep' ->> 'phone_verified_at')::timestamptz
       where id = (g.users_before -> 'keep' ->> 'id')::uuid;
    end if;
    update users set phone = g.users_before -> 'merged' ->> 'phone', phone_verified_at = (g.users_before -> 'merged' ->> 'phone_verified_at')::timestamptz
     where id = (g.users_before -> 'merged' ->> 'id')::uuid;
  end if;
  -- every moved row back
  for e in select x from jsonb_array_elements(g.moved) x loop
    for key in select y from jsonb_array_elements(e -> 'rows') y loop
      execute format('update %s x set %I = $1 where to_jsonb(x) @> $2 and x.%I = $3', e ->> 't', e ->> 'c', e ->> 'c') using g.merged_id, key, g.keep_id;
    end loop;
  end loop;
  update drivers set is_account_holder = true where id = any (g.holders) and renter_id = g.merged_id
     and not exists (select 1 from drivers d2 where d2.renter_id = g.merged_id and d2.is_account_holder);
  insert into reward_accounts select * from jsonb_populate_recordset(null::reward_accounts, g.removed) on conflict do nothing;
  update renter_merges set undone_at = now(), undone_by = p_by, undo_reason = nullif(btrim(coalesce(p ->> 'reason', '')), '') where id = g.id;
  insert into renter_edits (renter_id, edited_by, reason, before, after)
  values (g.keep_id, p_by, coalesce(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 'Merge undone'), app.renter_snapshot(g.keep_id), jsonb_build_object('merge_undone', g.id, 'merged_id', g.merged_id)),
         (g.merged_id, p_by, 'Merge undone: this record is separate again', app.renter_snapshot(g.merged_id), jsonb_build_object('merge_undone', g.id, 'keep_id', g.keep_id));
  return jsonb_build_object('ok', true, 'keep', g.keep_id, 'merged', g.merged_id);
end $$;

-- p: {renter}. The merges of a renter (kept or merged), newest first, for its page.
create or replace function app.renter_merges_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.may_edit_renter(p_by) then raise exception 'Customer service, sales and Admins see merges' using errcode = '42501'; end if;
  return jsonb_build_object('admin', coalesce(app.user_is_admin(p_by), false), 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', g.id, 'keep_id', g.keep_id, 'merged_id', g.merged_id, 'auto', g.auto, 'reason', g.reason,
             'keep_name', g.keep_before ->> 'legal_name', 'merged_name', g.merged_before ->> 'legal_name',
             'by', case when g.by_user is not null then (select coalesce(u.full_name, u.email) from users u where u.id = g.by_user) end,
             'aliases', to_jsonb(g.alias_emails), 'moved', (select coalesce(sum(jsonb_array_length(e -> 'rows')), 0) from jsonb_array_elements(g.moved) e),
             'at', g.created_at, 'undone_at', g.undone_at) order by g.created_at desc)
      from renter_merges g where g.keep_id = (p ->> 'renter')::uuid or g.merged_id = (p ->> 'renter')::uuid), '[]'::jsonb));
end $$;

-- ================================================================ 6. sign-in by any email
-- The kept account for an alias email, or for a sign-in that was merged into another (following a chain), else null.
create or replace function public.server_sign_in_alias(p_email text default null, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v uuid;
  i integer := 0;
  u users;
begin
  if nullif(btrim(coalesce(p_email, '')), '') is not null then
    select a.user_id into v from user_email_aliases a where a.email = lower(btrim(p_email));
  end if;
  if v is null and p_user is not null then select x.merged_into into v from users x where x.id = p_user; end if;
  if v is null then return null; end if;
  loop
    select * into u from users where id = v;
    exit when u.id is null or u.merged_into is null or i > 5;
    v := u.merged_into; i := i + 1;
  end loop;
  if u.id is null or u.status <> 'active' then return null; end if;
  return jsonb_build_object('user_id', u.id, 'email', u.email, 'phone', case when u.phone_verified_at is not null then u.phone end);
end $$;
revoke all on function public.server_sign_in_alias(text, uuid) from public, anon, authenticated;
grant execute on function public.server_sign_in_alias(text, uuid) to service_role;

-- ================================================================ 7. the note
insert into notification_catalogue (code, audience, category, subject, preheader, has_email, no_text, priority, emitted_by, timing, trigger_text, variables, template_html, template_text)
values ('renter_accounts_merged', 'renter', 'transactional', 'Your CarmaCars accounts are now one', 'Sign in with {{sign_in_emails}} or your phone number.', true, true, 2,
  'app.renter_merge_do (0955)', 'Immediate',
  'Two renter records of the same person were merged (automatically, or by staff with Merge into this record). Once per merge: the renter learns they can sign in with any of their emails or their phone number. Nothing else is sent about a merge.',
  '[{"name":"first_name","type":"string"},{"name":"sign_in_emails","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"instagram_url","type":"url","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb,
  'templates/renter_accounts_merged.html', 'templates/renter_accounts_merged.txt')
on conflict (code) do nothing;
select app.notification_catalogue_refresh();

-- ================================================================ 8. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0955;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'renter_merges') or (p_call in ('ops_do', 'admin_do') and p_name = 'renter_merge_undo') then
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'renter_merges' then app.renter_merges_read(p_user, p) else app.renter_merge_undo(p_user, p) end;
  end if;
  return app.door_pre0955(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0955(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 9. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['rm_vphone', 'rm_phone_personal', 'rm_strength', 'rm_auto_ok', 'rm_keep', 'renter_merge_do', 'renter_merge',
              'renter_merge_pre0955', 'renter_auto_merge', 'renter_merge_undo', 'renter_merges_read', 'door_pre0955', 'job_capture_pre0955'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
create trigger audit_user_email_aliases after insert or update or delete on user_email_aliases for each row execute function app.audit_row();
create trigger audit_renter_merges after insert or update or delete on renter_merges for each row execute function app.audit_row();
create policy admin_all on user_email_aliases for select to authenticated using (app.is_admin());
create policy admin_all on renter_merges for select to authenticated using (app.is_admin());
revoke all on user_email_aliases, renter_merges from anon, authenticated;
grant select, insert, update, delete on user_email_aliases, renter_merges to service_role;

-- ================================================================ 10. once: today's duplicates
select app.renter_auto_merge(now(), 1000);
