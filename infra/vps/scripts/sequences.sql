-- Every sequence at least at its column's max (run by copy.sh after the data load). The hosted dump's setval lines did
-- not reach the server on the October 23, 2026 cutover: ten public sequences (audit_log, app_events, ...) started at 1,
-- and every audited write failed with a duplicate key until they were set by hand. Never moves a sequence back.
-- Prints one row per sequence it moved (name, was, now).
create temp table if not exists _seq_fixed (seq text, was bigint, now bigint);
truncate _seq_fixed;
do $$
declare r record; m bigint; lv bigint; called boolean;
begin
  for r in
    select distinct s.oid::regclass::text as seq, n.nspname as sch, c.relname as tbl, a.attname as col
      from pg_class s
      join pg_depend d on d.objid = s.oid and d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a', 'i')
      join pg_class c on c.oid = d.refobjid join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attnum = d.refobjsubid
     where s.relkind = 'S' and n.nspname not in ('pg_catalog', 'information_schema')
    union
    select distinct substring(pg_get_expr(ad.adbin, ad.adrelid) from 'nextval\(''([^'']+)''')::regclass::text, n.nspname, c.relname, a.attname
      from pg_attrdef ad join pg_class c on c.oid = ad.adrelid join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attnum = ad.adnum
     where pg_get_expr(ad.adbin, ad.adrelid) like 'nextval(%' and n.nspname not in ('pg_catalog', 'information_schema')
  loop
    begin
      execute format('select max(%I)::bigint from %I.%I', r.col, r.sch, r.tbl) into m;
      execute format('select last_value, is_called from %s', r.seq) into lv, called;
      if m is not null and (m > lv or (m = lv and not called)) then
        perform setval(r.seq, m, true);
        insert into _seq_fixed values (r.seq, lv, m);
      end if;
    exception when others then
      raise notice 'sequence % not checked: %', r.seq, sqlerrm;
    end;
  end loop;
end $$;
select seq, was, now from _seq_fixed order by seq;
