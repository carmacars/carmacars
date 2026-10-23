#!/usr/bin/env bash
# Fix: sequences behind their table's max id after the copy (audit_log_pkey duplicates break every audited write).
source .github/vpscheck/common.sh
cat > "$RUNNER_TEMP/seq.sql" <<'SQL'
create temp table _seqs as
select distinct s.oid::regclass::text as seq, n.nspname as sch, c.relname as tbl, a.attname as col
from pg_class s
join pg_depend d on d.objid = s.oid and d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a','i')
join pg_class c on c.oid = d.refobjid join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum = d.refobjsubid
where s.relkind = 'S'
union
select distinct substring(pg_get_expr(ad.adbin, ad.adrelid) from 'nextval\(''([^'']+)''')::regclass::text, n.nspname, c.relname, a.attname
from pg_attrdef ad join pg_class c on c.oid = ad.adrelid join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum = ad.adnum
where pg_get_expr(ad.adbin, ad.adrelid) like 'nextval(%';
do $$
declare r record; m bigint; lv bigint; called boolean; n int := 0;
begin
  for r in select * from _seqs where sch not in ('pg_catalog','information_schema') loop
    begin
      execute format('select max(%I)::bigint from %I.%I', r.col, r.sch, r.tbl) into m;
      execute format('select last_value, is_called from %s', r.seq) into lv, called;
      if m is not null and (m > lv or (m = lv and not called)) then
        perform setval(r.seq, m, true);
        raise notice 'FIXED % (%.%.%): was % now %', r.seq, r.sch, r.tbl, r.col, lv, m;
        n := n + 1;
      end if;
    exception when others then raise notice 'SKIP % : %', r.seq, sqlerrm;
    end;
  end loop;
  raise notice 'sequences fixed: %', n;
end $$;
select count(*) from _seqs;
SQL
say "== sequences behind their column's max (fixed)"
q < "$RUNNER_TEMP/seq.sql" | grep -E 'NOTICE|^[0-9]+$' | sed 's/^psql:[^ ]* //' | sayf
say "== again (expect 0 fixed)"
q < "$RUNNER_TEMP/seq.sql" | grep -E 'sequences fixed' | sayf
flush seqfix
