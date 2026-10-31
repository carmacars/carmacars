-- 0233: every class picker reads the real class list (docs/changes/2026-11-03-vehicle-classes-everywhere.md).
-- The owner: Settings > Fee defaults offered Economy, Standard, Premium, Luxury and Exotic, but the site has 11 classes
-- (Settings > Vehicle classes: SUV, Van, Convertible, Coupe, Sedan, Pickup...). The single-class columns (a car's
-- pricing class vehicles.class, fee_defaults, required_shots, service_item_rules and vehicle_class_rules) are the enum
-- vehicle_class of 0001, which had six of them.
--
-- 1. The enum gets every class of vehicle_classes, and keeps them: a class added in Settings is added to it, a code
--    renamed is renamed in it (vehicle_classes_enum trigger).
-- 2. A fee default for a class applies to the cars of that pricing class (as before): a car's pricing class may now be any
--    class of the list (Cars, the car, Deposit class), so a default for Van applies to a car priced as a Van.
-- 3. The class lists of Settings > Maintenance and Settings > Class rules come from vehicle_classes, in its order, with
--    its labels. The forms of the website read the same list (web: the fee defaults, a car's pricing class, Add a car).
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0233: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the enum has every class
do $$
declare c record;
begin
  for c in select code from vehicle_classes order by sort_order, code loop
    execute format('alter type vehicle_class add value if not exists %L', c.code);
  end loop;
end $$;

create or replace function app.vehicle_classes_enum() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and new.code is distinct from old.code
     and exists (select 1 from pg_enum e where e.enumtypid = 'vehicle_class'::regtype and e.enumlabel = old.code)
     and not exists (select 1 from pg_enum e where e.enumtypid = 'vehicle_class'::regtype and e.enumlabel = new.code) then
    execute format('alter type vehicle_class rename value %L to %L', old.code, new.code);
  else
    execute format('alter type vehicle_class add value if not exists %L', new.code);
  end if;
  return new;
end $$;
revoke all on function app.vehicle_classes_enum() from public, anon, authenticated;
grant execute on function app.vehicle_classes_enum() to service_role;
drop trigger if exists vehicle_classes_enum on vehicle_classes;
create trigger vehicle_classes_enum after insert or update of code on vehicle_classes for each row execute function app.vehicle_classes_enum();

-- ================================================================ 3. the class lists of Maintenance and Class rules
select pg_temp.patch_fn('app.maint_settings_read()'::regprocedure,
  $o$'classes', (select jsonb_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = 'vehicle_class'::regtype),$o$,
  $n$'classes', (select jsonb_agg(c.code order by c.sort_order, c.code) from vehicle_classes c where c.is_active),
    'class_labels', (select jsonb_object_agg(c.code, c.label) from vehicle_classes c),$n$);
select pg_temp.patch_fn('app.class_rules_read(uuid)'::regprocedure,
  $o$    'classes', coalesce((select jsonb_agg(jsonb_build_object('code', e.v, 'label', app.class_label(e.v)) order by e.o)
                           from (select v::text, row_number() over () as o from unnest(enum_range(null::vehicle_class)) v) e), '[]'::jsonb));$o$,
  $n$    'classes', coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label) order by c.sort_order, c.code)
                           from vehicle_classes c where c.is_active), '[]'::jsonb));$n$);
