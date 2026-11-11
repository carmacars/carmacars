-- 1600_r35sec_hardening.sql
-- Release 35, security audit (helper SEC). The owner: "Make sure the website is extremely secure, and there are no gaps in
-- the cyber security of the entire website and backend". What the audit found in the database, and what this changes
-- (supabase/tests/99_r35sec_security.sql proves each one and fails if a later migration reopens it):
--   1. Row-level security on every table of the app schema too. 13 internal tables there (the sign-in code log, the phone
--      gate codes, the CRM secrets, caches) had it off. No browser role was granted them, so nothing leaked; with it on, a
--      grant added by mistake later still shows nothing. Only the server (service_role, which bypasses it) and the
--      database's own functions read them, so nothing changes for them.
--   2. No SECURITY DEFINER function is executable by PUBLIC. 0012 meant "closed by default" for the app schema with
--      "alter default privileges in schema app revoke execute on functions from public", but PostgreSQL cannot revoke per
--      schema what it grants globally (functions are executable by PUBLIC unless revoked one by one), so 20 older
--      definer functions kept PUBLIC execute (trigger functions, old copies kept for history, a few helpers). The app
--      schema is not served by the API, so none could be called from a browser; they are closed now all the same. Each
--      keeps exactly the explicit grants it had; one pure calculator a public wrapper uses (calc_cancellation) gets anon and
--      authenticated by name instead of through PUBLIC.
--   3. Browser roles cannot create temporary tables. A definer function's search_path ("public, app") does not name
--      pg_temp, so PostgreSQL looks in the session's temporary schema first: a session that could create a temp table
--      named like a real one could shadow it inside a definer function. Browser sessions never need temp tables (every
--      function that makes one is a definer function, run as the owner), so TEMPORARY is revoked from PUBLIC and given
--      back by name to every role that is not anon or authenticated.
--   4. staff_directory gets security_barrier like every other view a browser session reads.
--   5. Every foreign key that is a join path gets an index (538 had none; the audit's "missing indexes on foreign keys").
--      Without one, deleting or purging a parent row (the visitor retention purge, a booking's cascades) scans the child
--      table once per row, and the portals' joins scan too. Columns that only record who did something (created_by,
--      updated_by, approved_by and the like, ON DELETE NO ACTION to users) are left out: nothing looks rows up by them.
-- No applied migration is edited.

-- ================================================================ 1. row-level security on every app table
do $$
declare t record;
begin
  for t in select c.oid::regclass r from pg_class c where c.relnamespace = 'app'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity loop
    execute format('alter table %s enable row level security', t.r);
  end loop;
end $$;

-- ================================================================ 2. no definer function executable by PUBLIC
do $$
declare
  f record;
  g text;
begin
  for f in
    select p.oid, p.oid::regprocedure sig, n.nspname,
           coalesce((select array_agg(r.rolname) from aclexplode(p.proacl) a join pg_roles r on r.oid = a.grantee
                      where a.privilege_type = 'EXECUTE' and r.rolname in ('anon', 'authenticated', 'service_role')), '{}') explicit
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
       and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
    foreach g in array f.explicit loop
      execute format('grant execute on function %s to %I', f.sig, g);
    end loop;
  end loop;
end $$;
-- public.calc_refund_bps (a calculator anon may call) calls it with the caller's rights
grant execute on function public.calc_cancellation(timestamptz, timestamptz, timestamptz, boolean, bigint, boolean) to anon, authenticated;

-- ================================================================ 3. no temporary tables for browser sessions
do $$
declare r record;
begin
  execute format('revoke temporary on database %I from public', current_database());
  for r in select rolname from pg_roles where rolname !~ '^pg_' and rolname not in ('anon', 'authenticated') loop
    execute format('grant temporary on database %I to %I', current_database(), r.rolname);
  end loop;
exception when insufficient_privilege then
  raise notice 'temporary: not the database owner here, left as it was (%)', sqlerrm;
end $$;

-- ================================================================ 4. the staff directory view
alter view public.staff_directory set (security_barrier = true);

-- ================================================================ 5. an index for every join-path foreign key
-- Named <table>_<columns>_fk, cut to 55 characters plus a short hash so two long names never collide.
-- A key whose every column only records who did something (the test uses the same rule for later tables).
create function app.fk_is_actor_column(p_constraint oid) returns boolean
language sql stable set search_path = pg_catalog as $$
  select coalesce(bool_and(a.attname ~ '(_by|_by_user|_by_id|^by|^by_user|approver|reviewer)$'), false)
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
   where c.oid = p_constraint
$$;
revoke all on function app.fk_is_actor_column(oid) from public, anon, authenticated;
grant execute on function app.fk_is_actor_column(oid) to service_role;

do $$
declare
  f record;
  v_name text;
begin
  for f in
    select c.conrelid, c.conrelid::regclass tbl, cl.relname,
           (select string_agg(quote_ident(a.attname), ', ' order by k.ord) from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) cols,
           (select string_agg(a.attname, '_' order by k.ord) from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) col_names
      from pg_constraint c join pg_class cl on cl.oid = c.conrelid
     where c.contype = 'f' and c.connamespace in ('public'::regnamespace, 'app'::regnamespace)
       and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                         and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey
                         and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] <@ c.conkey)
       and not (c.confdeltype = 'a' and app.fk_is_actor_column(c.oid))
     order by 2, 4
  loop
    v_name := f.relname || '_' || f.col_names || '_fk';
    if length(v_name) > 63 then v_name := left(v_name, 55) || '_' || left(md5(v_name), 7); end if;
    execute format('create index if not exists %I on %s (%s)', v_name, f.tbl, f.cols);
  end loop;
end $$;
