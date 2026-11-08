-- 0790: a paper signature is refused with its reason first (Release 33, part M: the fixes from the r33 end-to-end run).
-- SCHEMA_MARKER 0790. No applied migration is edited; app.record_paper_signature is wrapped (suffix _pre0790).
--
-- 0720 refuses every new paper signature (except the ServiceOntario forms signed in ink, registry_form) with a trigger
-- on the insert. app.record_paper_signature checks its own inputs before it inserts, so an Admin (or the Claude
-- connector acting as one) who asked to record an agreement signed on paper was told "Upload the scan of the signed
-- document", then, with a scan uploaded, that paper is no longer recorded. The refusal now comes first, after the
-- check of who may record it: the sentence of 0720 (and 0710's for a fleet supplier's documents). The ServiceOntario
-- forms and the database tests' fixtures (app.paper_fixture) go through as before.
set local check_function_bodies = off;

alter function app.record_paper_signature(uuid, jsonb) rename to record_paper_signature_pre0790;
create function app.record_paper_signature(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := p ->> 'doc_type';
  v_owner uuid;
begin
  if app.paper_fixture() or v_type = 'registry_form' then return app.record_paper_signature_pre0790(p_by, p); end if;
  -- who may record (0044), unchanged
  if p_by is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if v_type in ('rental_agreement', 'rental_amendment') then
    if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs')) then
      raise exception 'Only an Admin or customer service records a rental document signed on paper' using errcode = '42501';
    end if;
  else
    perform app.assert_admin(p_by);
  end if;
  -- a fleet supplier's documents: 0710's sentence
  begin
    if v_type in ('owner_agreement', 'form_a', 'form_b', 'form_d') then v_owner := nullif(p ->> 'target_id', '')::uuid;
    elsif v_type = 'form_c' then v_owner := (select owner_id from vehicles where id = nullif(p ->> 'target_id', '')::uuid);
    end if;
  exception when invalid_text_representation then v_owner := null;
  end;
  if v_owner is not null and app.fleet_supplier(v_owner) then
    raise exception 'A fleet supplier signs in the owner portal only (the e-signature with its audit trail): no paper signature is recorded' using errcode = '23514';
  end if;
  raise exception '%', app.paper_message() using errcode = '23514';
end $$;

do $$
declare g text;
begin
  execute 'revoke all on function app.record_paper_signature(uuid, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.record_paper_signature_pre0790(uuid, jsonb)', 'execute') then
      execute format('grant execute on function app.record_paper_signature(uuid, jsonb) to %I', g);
    end if;
  end loop;
end $$;
