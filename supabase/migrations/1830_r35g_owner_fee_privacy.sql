-- r35 gaps, item 1 (owner, 2624): a car owner never sees what CarmaCars charges a renter for the young driver fee or the
-- Protection Plan (or any other coverage the company sells). Not on statements, booking views, invoices or anything else the
-- owner portal reads. The owner reads are the public owner_portal_* functions: each now returns its result through
-- app.owner_redact, so whatever a later change adds to the underlying views, those charges never reach an owner.

-- The charges an owner never sees: the young driver bands and the coverage the company sells (the Protection Plan is
-- coverage_sold; the loss-damage waivers and personal accident cover are the same kind of charge).
create or replace function app.owner_hidden_fee_codes() returns text[]
language sql immutable as $$
  select array['young_driver_18_20', 'young_driver_21_25', 'coverage_sold', 'ldw', 'tldw', 'pap_pec', 'waiver_saver']
$$;

-- Removes, at any depth: a key that names those charges (young_driver..., protection..., coverage_sold, rentalcover...,
-- the waivers), and an array element that is one of those charges (its code, fee type or charge type is a hidden code).
create or replace function app.owner_redact(p jsonb) returns jsonb
language plpgsql immutable set search_path = public, app as $$
declare
  v_out jsonb;
  k text;
  v jsonb;
  v_hidden text[] := app.owner_hidden_fee_codes();
  v_key_re constant text := '(^|_)(young|youngdriver|protection|coverage_sold|coverage_price|coverage_cents|rentalcover|ldw|tldw|pap_pec|waiver)';
begin
  if p is null then return null; end if;
  case jsonb_typeof(p)
    when 'object' then
      v_out := '{}'::jsonb;
      for k, v in select * from jsonb_each(p) loop
        continue when lower(k) ~ v_key_re;
        v_out := v_out || jsonb_build_object(k, app.owner_redact(v));
      end loop;
      return v_out;
    when 'array' then
      return coalesce((select jsonb_agg(app.owner_redact(e) order by o)
                         from jsonb_array_elements(p) with ordinality x(e, o)
                        where not (jsonb_typeof(e) = 'object'
                                   and (coalesce(e ->> 'code', e ->> 'fee_type_code', e ->> 'charge_type', e ->> 'fee_type', '') = any (v_hidden)))),
                      '[]'::jsonb);
    else
      return p;
  end case;
end $$;

create or replace function public.owner_portal_home(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_redact(app.owner_portal_home(p_by)) $$;
create or replace function public.owner_portal_invoice(p_by uuid, p_number text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_redact(app.owner_portal_invoice(p_by, p_number)) $$;
create or replace function public.owner_portal_statement(p_by uuid, p_statement uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_redact(app.owner_portal_statement(p_by, p_statement)) $$;
create or replace function public.owner_portal_bookings(p_by uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_redact(app.owner_portal_bookings_json(p_by, p_from, p_to)) $$;
create or replace function public.owner_portal_month_to_date(p_by uuid, p_month date default null) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_redact(app.owner_month_to_date(p_by, p_month)) $$;

revoke all on function app.owner_redact(jsonb), app.owner_hidden_fee_codes() from public, anon, authenticated;
grant execute on function app.owner_redact(jsonb), app.owner_hidden_fee_codes() to service_role;
