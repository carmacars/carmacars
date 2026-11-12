-- 2580_r41_newest_first.sql
-- Release 41. The owner, Nov 12: "In a lot of places on the website, e.g. the renters, bookings and offers, leads and hiring,
-- it's not ordered the right way. It should be chronological in the order it came in, not alphabetical."
-- Lists show the newest record first, by the time it came in, with the id as the tie-breaker:
--   1. app.admin_list (every Admin and staff list of a table): with no order asked for, the first of created_at, submitted_at,
--      received_at, requested_at, occurred_at, issued_at, sent_at, started_at, at, changed_at, updated_at the table has (a table
--      with none of them used to fall back to its first column, so a list could come out alphabetical or by random id); an
--      order that is asked for still wins, and every order now ends on the id.
--   2. Hiring > Applications: newest application first (it was highest screening score first; the ranked Shortlist tab is unchanged).
--   3. Leads (Admin, Sales, customer service): the default sort is Newest (it was Priority; Priority and Oldest stay as choices).
-- docs/changes/2026-11-12-r41-newest-first.md. No applied migration is edited.
create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2580: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- 1. the generic list
select pg_temp.patch_fn('app.admin_list(uuid, text, jsonb)'::regprocedure,
  '  v_order := coalesce(p ->> ''order'', case when ''created_at'' = any (v_cols) then ''created_at'' end, v_cols[1]);',
  '  v_order := coalesce(nullif(p ->> ''order'', ''''),
                      (select c from unnest(array[''created_at'', ''submitted_at'', ''received_at'', ''requested_at'', ''occurred_at'', ''issued_at'', ''sent_at'',
                                                  ''started_at'', ''at'', ''changed_at'', ''updated_at'']) c where c = any (v_cols) limit 1),
                      v_cols[1]);');
select pg_temp.patch_fn('app.admin_list(uuid, text, jsonb)'::regprocedure,
  'order by t.%I %s nulls last), ''[]''::jsonb)
                    from (select * from public.%I t where %s order by t.%I %s nulls last limit %s offset %s) t'',
                 v_order, case when coalesce((p ->> ''asc'')::boolean, false) then ''asc'' else ''desc'' end,
                 p_rel, v_where, v_order, case when coalesce((p ->> ''asc'')::boolean, false) then ''asc'' else ''desc'' end, v_limit, v_offset)',
  'order by t.%I %s nulls last%s), ''[]''::jsonb)
                    from (select * from public.%I t where %s order by t.%I %s nulls last%s limit %s offset %s) t'',
                 v_order, case when coalesce((p ->> ''asc'')::boolean, false) then ''asc'' else ''desc'' end, case when ''id'' = any (v_cols) and v_order <> ''id'' then '', t.id desc'' else '''' end,
                 p_rel, v_where, v_order, case when coalesce((p ->> ''asc'')::boolean, false) then ''asc'' else ''desc'' end, case when ''id'' = any (v_cols) and v_order <> ''id'' then '', t.id desc'' else '''' end, v_limit, v_offset)');

-- 2. Hiring > Applications (the original read that 0211, 0226, 0380 and 0585 wrap)
select pg_temp.patch_fn('app.hiring_read_pre0211(uuid, jsonb)'::regprocedure,
  'order by a.score desc nulls last, a.created_at desc), ''[]''::jsonb)',
  'order by a.created_at desc, a.id desc), ''[]''::jsonb)');
select pg_temp.patch_fn('app.hiring_read_pre0211(uuid, jsonb)'::regprocedure,
  'order by x.score desc nulls last, x.created_at desc limit 500) a)',
  'order by x.created_at desc, x.id desc limit 500) a)');

-- 3. the lead list: Newest by default
select pg_temp.patch_fn('app.sales_leads_pre1152(uuid, jsonb)'::regprocedure,
  'coalesce(nullif(p ->> ''sort'', ''''), ''priority'')',
  'coalesce(nullif(p ->> ''sort'', ''''), ''newest'')');
select pg_temp.patch_fn('app.sales_leads_pre1152(uuid, jsonb)'::regprocedure,
  'case when v_sort = ''oldest'' then f.at end asc nulls last, f.at desc',
  'case when v_sort = ''oldest'' then f.at end asc nulls last, f.at desc, (f.r).id desc');
select pg_temp.patch_fn('app.sales_leads_pre1152(uuid, jsonb)'::regprocedure,
  'case when v_sort = ''oldest'' then pg.at end asc nulls last, pg.at desc)',
  'case when v_sort = ''oldest'' then pg.at end asc nulls last, pg.at desc, (pg.r).id desc)');
