-- 5151 (r50 hotfix 2, UX: docs/changes/2026-11-27-r50h2-ux.md): the discount games inside Rewards, for every kind of user.
-- SCHEMA_MARKER 5151. No applied migration is edited.
--   The owner: the games can be played in the Rewards section by every type of user (renter, owner, staff) and the
--   points accumulate in rewards.
--   * A play in Rewards wins CarmaCars Rewards points, never a discount code: the site's game (0069 to 5040) keeps its
--     codes for visitors. The points prize table is its own Program setting (rewards_game_prizes: key, weight, points), so
--     the value given away a day is small and set by an Admin, and the site's code prizes are never handed out here.
--   * The existing rules hold: the games' switch (game_enabled) and the day's cap (game_max_per_day; 0 there means no cap
--     on the site, so Rewards uses 1 a day), the games and their weights (game_weights). The prize is drawn here; the game
--     only shows it. A test account plays but is never credited (as every reward).
--   * Points go to the person's renter rewards account (reward_ledger, action game, source game:<play>, once). A person
--     with no renter account yet (an owner or staff member who never rented) keeps the points on the play; they move to
--     the account by themselves once it exists (app.rewards_game_bank, at each read and play). Redeeming follows the
--     existing rules (0214: at least 500 points, a code of their own, the rental charge only).
--   * public.server_rewards_game(p_by, p_action, p): service_role only; the web layer passes the signed-in user.


create or replace function app.rewards_game_prizes_ok(p jsonb) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) between 1 and 12
     and not exists (select 1 from jsonb_array_elements(p) x
                      where jsonb_typeof(x) <> 'object' or coalesce(x ->> 'key', '') !~ '^[a-z0-9_]{1,20}$'
                         or jsonb_typeof(x -> 'weight') <> 'number' or (x ->> 'weight')::numeric <= 0
                         or jsonb_typeof(x -> 'points') <> 'number' or (x ->> 'points')::numeric <> trunc((x ->> 'points')::numeric) or (x ->> 'points')::int not between 1 and 1000)
$$;

alter table program_settings
  add column if not exists rewards_game_on boolean not null default true,
  add column if not exists rewards_game_prizes jsonb not null default
    '[{"key":"p10","weight":50,"points":10},{"key":"p25","weight":30,"points":25},{"key":"p50","weight":14,"points":50},{"key":"p100","weight":5,"points":100},{"key":"p250","weight":1,"points":250}]'::jsonb
    check (app.rewards_game_prizes_ok(rewards_game_prizes));
comment on column program_settings.rewards_game_on is 'Rewards game (5151): the games inside Rewards for renters, owners and staff (also off when game_enabled is off).';
comment on column program_settings.rewards_game_prizes is 'Rewards game (5151): the points prizes. Each: key, weight (its chance), points (1 to 1000). Every play wins one. Plays a day: game_max_per_day, or 1 when that is 0.';

insert into reward_actions (code, label, detail, points, enabled, limit_text, sort)
values ('game', 'Rewards game', 'Points won in the game in Rewards (the prize table is in Program settings, rewards_game_prizes).', 0, true, 'The plays a day of the game', 12)
on conflict (code) do nothing;

create table if not exists reward_game_plays (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  portal     text not null check (portal in ('renter', 'owner', 'staff')),
  day        date not null,
  game       text not null check (game ~ '^[a-z]{2,20}$'),
  prize_key  text not null,
  points     integer not null check (points between 1 and 1000),
  test       boolean not null default false,
  renter_id  uuid references renters (id) on delete set null,
  ledger_id  uuid references reward_ledger (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists reward_game_plays_user on reward_game_plays (user_id, day);
create index if not exists reward_game_plays_renter on reward_game_plays (renter_id) where renter_id is not null;
create index if not exists reward_game_plays_ledger on reward_game_plays (ledger_id) where ledger_id is not null;
comment on table reward_game_plays is 'Rewards game (5151): each play in Rewards, its prize in points, and the ledger row it became (null while the person has no renter account, or a test account).';
alter table reward_game_plays enable row level security;
revoke all on reward_game_plays from public, anon, authenticated;
grant all on reward_game_plays to service_role;
drop policy if exists admin_all on reward_game_plays;
create policy admin_all on reward_game_plays for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_reward_game_plays on reward_game_plays;
create trigger audit_reward_game_plays after insert or update or delete on reward_game_plays for each row execute function app.audit_row();

-- the plays a day in Rewards
create or replace function app.rewards_game_cap() returns integer
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when s.game_max_per_day > 0 then s.game_max_per_day else 1 end from app.settings() s
$$;

-- who may play from which portal
create or replace function app.rewards_game_may(p_user uuid, p_portal text) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from users u where u.id = p_user and coalesce(u.status::text, 'active') = 'active')
     and case p_portal
           when 'renter' then app.rewards_renter_of(p_user) is not null
           when 'owner' then exists (select 1 from owners o where o.user_id = p_user)
           when 'staff' then app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user)
           else false end
$$;

-- points won before the person had a renter account join it once it exists
create or replace function app.rewards_game_bank(p_user uuid) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_renter uuid := app.rewards_renter_of(p_user);
  g reward_game_plays;
  n integer := 0;
begin
  if v_renter is null or app.is_test_user(p_user) or app.renter_is_test(v_renter) then return 0; end if;
  for g in select * from reward_game_plays where user_id = p_user and ledger_id is null and not test order by created_at for update loop
    n := n + app.rewards_award(v_renter, 'game', 'game:' || g.id, g.points, null, 'Rewards game: ' || g.points || ' points', jsonb_build_object('play', g.id, 'game', g.game, 'portal', g.portal));
    update reward_game_plays set renter_id = v_renter, ledger_id = (select l.id from reward_ledger l where l.source_key = 'game:' || g.id) where id = g.id;
  end loop;
  return n;
end $$;

create or replace function app.rewards_game_words(p jsonb) returns jsonb
language sql immutable set search_path = public, app, pg_temp as $$
  select jsonb_build_object('key', p ->> 'key', 'short', (p ->> 'points'), 'label', (p ->> 'points') || ' points', 'points', (p ->> 'points')::int, 'note', 'Rewards points')
$$;

create or replace function app.rewards_game_state(p_user uuid, p_portal text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_renter uuid;
  v_today date := app.local_date(now());
  v_played integer;
begin
  if not app.rewards_game_may(p_user, p_portal) then raise exception 'Not permitted' using errcode = '42501'; end if;
  perform app.rewards_game_bank(p_user);
  v_renter := app.rewards_renter_of(p_user);
  select count(*) into v_played from reward_game_plays where user_id = p_user and day = v_today;
  return jsonb_build_object('on', s.game_enabled and s.rewards_game_on, 'cap', app.rewards_game_cap(), 'played_today', v_played,
    'left', greatest(app.rewards_game_cap() - v_played, 0), 'test', app.is_test_user(p_user),
    'has_account', v_renter is not null, 'balance', case when v_renter is not null then app.rewards_balance(v_renter) end,
    'waiting', (select coalesce(sum(points), 0) from reward_game_plays where user_id = p_user and ledger_id is null and not test),
    'won_total', (select coalesce(sum(points), 0) from reward_game_plays where user_id = p_user and not test),
    'prizes', (select jsonb_agg(app.rewards_game_words(x) order by (x ->> 'points')::int) from jsonb_array_elements(s.rewards_game_prizes) x),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', g.created_at, 'game', g.game, 'points', g.points) order by g.created_at desc)
                          from (select * from reward_game_plays where user_id = p_user order by created_at desc limit 5) g), '[]'::jsonb));
end $$;

-- one play: the cap, the draw, the game, the points (once per play)
create or replace function app.rewards_game_play(p_user uuid, p_portal text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings();
  v_today date := app.local_date(now());
  v_total numeric;
  v_r numeric;
  v_prize jsonb;
  v_game text;
  g reward_game_plays;
begin
  if not app.rewards_game_may(p_user, p_portal) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if not (s.game_enabled and s.rewards_game_on) then raise exception 'The games are off for now' using errcode = '23514'; end if;
  perform pg_advisory_xact_lock(hashtext('rewards_game:' || p_user));
  if (select count(*) from reward_game_plays where user_id = p_user and day = v_today) >= app.rewards_game_cap() then
    raise exception 'You played today''s game%: come back tomorrow', case when app.rewards_game_cap() > 1 then 's' else '' end using errcode = '23514';
  end if;
  -- the prize: weighted by the table
  select sum((x ->> 'weight')::numeric) into v_total from jsonb_array_elements(s.rewards_game_prizes) x;
  v_r := random() * v_total;
  select x into v_prize from (select x, sum((x ->> 'weight')::numeric) over (order by o) c from jsonb_array_elements(s.rewards_game_prizes) with ordinality t(x, o)) y
   where y.c > v_r order by y.c limit 1;
  v_prize := coalesce(v_prize, s.rewards_game_prizes -> 0);
  -- the game: weighted by the site's game weights (only the games with weight above 0)
  select sum(value::numeric) into v_total from jsonb_each_text(s.game_weights) where value::numeric > 0;
  v_r := random() * coalesce(v_total, 0);
  select key into v_game from (select key, sum(value::numeric) over (order by key) c from jsonb_each_text(s.game_weights) where value::numeric > 0) y where y.c > v_r order by y.c limit 1;
  insert into reward_game_plays (user_id, portal, day, game, prize_key, points, test)
  values (p_user, p_portal, v_today, coalesce(v_game, 'wheel'), v_prize ->> 'key', (v_prize ->> 'points')::int, app.is_test_user(p_user))
  returning * into g;
  perform app.rewards_game_bank(p_user);
  return jsonb_build_object('id', g.id, 'game', g.game, 'prize', app.rewards_game_words(v_prize), 'credited', not g.test) || app.rewards_game_state(p_user, p_portal);
end $$;

-- the web layer: the signed-in user, never from the browser
create or replace function public.server_rewards_game(p_by uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_portal text := coalesce(p ->> 'portal', '');
begin
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_action = 'state' then return app.rewards_game_state(p_by, v_portal); end if;
  if p_action = 'play' then
    return app.rewards_game_play(p_by, v_portal);
  end if;
  raise exception 'Unknown action' using errcode = '22023';
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['rewards_game_prizes_ok', 'rewards_game_cap', 'rewards_game_may', 'rewards_game_bank', 'rewards_game_words',
                    'rewards_game_state', 'rewards_game_play']))
               or (n.nspname = 'public' and p.proname = 'server_rewards_game') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
