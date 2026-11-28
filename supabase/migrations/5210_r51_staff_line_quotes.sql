-- 5210 (R51 review fix 2): buying a staff line buys exactly the number that was quoted, once.
--   staff_line_quotes: the number Twilio offered at the quote (server only, never shown: an Admin sees its last 4 digits),
--   its monthly price and currency. One row a staff member, so a second quote replaces the first.
--   server_staff_line_claim: the Buy step. It locks the row, checks the Admin's confirmed price and currency against the
--   quote, and marks the purchase in progress; a second Buy for the same staff member while one is in progress is refused
--   (the mark ends when the purchase ends, or after 10 minutes if the server died).
set local check_function_bodies = off;

create table staff_line_quotes (
  user_id    uuid primary key references staff_phone_lines (user_id) on delete cascade,
  number     text not null check (number ~ '^\+[1-9][0-9]{7,14}$'),
  monthly    text not null check (monthly ~ '^[0-9]+(\.[0-9]+)?$'),
  currency   text not null check (currency ~ '^[A-Z]{3}$'),
  quoted_by  uuid not null references users (id),
  quoted_at  timestamptz not null default now(),
  buying_at  timestamptz
);
comment on table staff_line_quotes is 'Staff lines (5210): the number and price quoted to an Admin, kept for the Buy step. Server only; the number is never shown.';
alter table staff_line_quotes enable row level security;
create policy admin_all on staff_line_quotes for select to authenticated using (false);
revoke all on staff_line_quotes from public, anon, authenticated;
grant select, insert, update, delete on staff_line_quotes to service_role;
-- audited without values: the number is never copied into audit_log
create trigger audit_staff_line_quotes after insert or update or delete on staff_line_quotes for each row execute function app.audit_row('redact');

-- p: {by, user_id, number, monthly, currency}
create function app.server_staff_line_quoted(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_by uuid := nullif(p ->> 'by', '')::uuid;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  q staff_line_quotes;
begin
  perform app.server_staff_line_check(v_by, v_user);
  select * into q from staff_line_quotes where user_id = v_user for update;
  if q.user_id is not null and q.buying_at > now() - interval '10 minutes' then
    raise exception 'A purchase for this person is in progress' using errcode = '55P03';
  end if;
  insert into staff_line_quotes (user_id, number, monthly, currency, quoted_by)
  values (v_user, app.phone_e164(p ->> 'number'), p ->> 'monthly', upper(p ->> 'currency'), v_by)
  on conflict (user_id) do update set number = excluded.number, monthly = excluded.monthly, currency = excluded.currency,
    quoted_by = excluded.quoted_by, quoted_at = now(), buying_at = null;
  return jsonb_build_object('ok', true);
end $$;

-- the Buy step: the quoted number, if the Admin confirmed the quoted price and currency and no purchase is in progress
create function app.server_staff_line_claim(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_by uuid := nullif(p ->> 'by', '')::uuid;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  q staff_line_quotes;
begin
  perform app.server_staff_line_check(v_by, v_user);
  select * into q from staff_line_quotes where user_id = v_user for update;
  if q.user_id is null or q.quoted_at < now() - interval '30 minutes' then
    raise exception 'The quote is gone or too old. Nothing was bought: press Get a number again.' using errcode = 'P0002';
  end if;
  if q.buying_at is not null and q.buying_at > now() - interval '10 minutes' then
    raise exception 'A purchase for this person is already in progress. Nothing more was bought.' using errcode = '55P03';
  end if;
  if q.monthly <> coalesce(p ->> 'confirm', '') or q.currency <> upper(coalesce(p ->> 'currency', '')) then
    raise exception 'The price you confirmed is not the one quoted (% % a month). Nothing was bought: press Get a number again.', q.currency, q.monthly using errcode = '22023';
  end if;
  update staff_line_quotes set buying_at = now() where user_id = v_user;
  return jsonb_build_object('number', q.number, 'monthly', q.monthly, 'currency', q.currency);
end $$;

-- the purchase ended (bought and saved, or nothing bought): the quote is spent
create function app.server_staff_line_quote_end(p_by uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  delete from staff_line_quotes where user_id = p_user;
end $$;

revoke all on function app.server_staff_line_quoted(jsonb), app.server_staff_line_claim(jsonb), app.server_staff_line_quote_end(uuid, uuid) from public, anon, authenticated;
grant execute on function app.server_staff_line_quoted(jsonb), app.server_staff_line_claim(jsonb), app.server_staff_line_quote_end(uuid, uuid) to service_role;

create function public.server_staff_line_quoted(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_quoted(p) $$;
create function public.server_staff_line_claim(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_claim(p) $$;
create function public.server_staff_line_quote_end(p_by uuid, p_user uuid) returns void
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_quote_end(p_by, p_user) $$;
revoke all on function public.server_staff_line_quoted(jsonb), public.server_staff_line_claim(jsonb), public.server_staff_line_quote_end(uuid, uuid) from public, anon, authenticated;
grant execute on function public.server_staff_line_quoted(jsonb), public.server_staff_line_claim(jsonb), public.server_staff_line_quote_end(uuid, uuid) to service_role;
