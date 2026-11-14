-- 2862 (release 45, part B): "Send a new agreement" for a staff agreement already sent or signed.
--
-- Release 44 (2820) gives staff who live in Canada Canadian terms, but an agreement already sent or signed with the old
-- terms (the Philippines, USD, OnlineJobs.ph) could not be redone: Settings > Staff offered only Waive for one waiting
-- and Send a PDF to sign for one signed.
--   1. sign_requests.superseded_at / superseded_by: a signed agreement replaced by a newer one stays on file, marked
--      superseded. A new staff agreement sent with extra.reissue (the site's "Send a new agreement", which prepares the
--      current terms with app.staff_agreement_prepare exactly as the first send) voids the one waiting, as every new
--      version already does (0044), and marks the signed one superseded. The signed one keeps the person's portal open
--      until they sign the new one.
--   2. app.staff_agreement_needs_canada(user): an active staff member who lives in Canada (app.staff_in_canada) whose
--      current agreement (the one waiting, else the newest signed one not superseded) was made with terms that are not
--      Canadian (a country other than Canada, a currency other than CAD, or paid through OnlineJobs.ph).
--   3. Admin > Settings > Staff, Staff agreements (ops_read staff_agreements) says for each person whether their
--      agreement needs the Canadian terms and whether a signed one was superseded.
--   4. One Admin To do, once, listing everyone affected so the owner's assistant sends each a new agreement. The
--      agreement is not sent from here: it is rendered to a PDF and stored by the website (server/person-agreements.ts),
--      which SQL cannot call. The To do closes by itself when the last of them has a new agreement.
-- No applied migration is edited: sign_request_create and staff_agreements are wrapped (_pre2862).
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

-- ================================================================ 1. superseded, and the new send
alter table sign_requests add column if not exists superseded_at timestamptz;
alter table sign_requests add column if not exists superseded_by uuid references sign_requests (id);
comment on column sign_requests.superseded_at is 'r45 (2862): a signed agreement replaced by a newer one (Send a new agreement). It stays on file.';

-- the terms an agreement was made with: Canadian, or not (null: no terms recorded, as for an uploaded PDF)
create function app.staff_terms_canadian(p_extra jsonb) returns boolean
language sql immutable as $$
  select case when jsonb_typeof(p_extra -> 'values') is distinct from 'object' then null
              when coalesce(nullif(btrim(p_extra #>> '{values,country}'), ''), 'Canada') !~* '^(canada|ca)$' then false
              when coalesce(nullif(btrim(p_extra #>> '{values,currency}'), ''), 'CAD') !~* '^cad$' then false
              when coalesce(p_extra #>> '{values,platform}', '') ~* 'onlinejobs' then false
              else true end
$$;

create function app.staff_current_agreement(p_user uuid) returns sign_requests
language sql stable security definer set search_path = public, app as $$
  select x.* from sign_requests x
   where x.staff_user_id = p_user and x.doc_type = 'staff_agreement' and x.superseded_at is null and x.status in ('sent', 'signed')
   order by (x.status = 'sent') desc, coalesce(x.signed_at, x.sent_at) desc
   limit 1
$$;

create function app.staff_agreement_needs_canada(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.staff_is_member(p_user) and app.staff_in_canada(p_user)
     and coalesce((select app.staff_terms_canadian(a.extra) = false from app.staff_current_agreement(p_user) a where a.id is not null), false)
$$;
comment on function app.staff_agreement_needs_canada(uuid) is 'r45 (2862): an active staff member in Canada whose current staff agreement (waiting, or signed) carries terms that are not Canadian.';

alter function app.sign_request_create(uuid, jsonb) rename to sign_request_create_pre2862;
create function app.sign_request_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_reissue boolean := p ->> 'doc_type' = 'staff_agreement' and coalesce((p #>> '{extra,reissue}')::boolean, false);
  v_user uuid := nullif(p ->> 'staff_user_id', '')::uuid;
  v_out jsonb;
  v_new uuid;
  v_old uuid[];
begin
  v_out := app.sign_request_create_pre2862(p_by, p);
  if v_reissue then
    v_new := (v_out ->> 'id')::uuid;
    with s as (
      update sign_requests set superseded_at = now(), superseded_by = v_new
       where staff_user_id = v_user and doc_type = 'staff_agreement' and status = 'signed' and superseded_at is null and id <> v_new
      returning id)
    select array_agg(id) into v_old from s;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'staff_agreement_reissued', 'sign_requests', v_new::text, jsonb_build_object('superseded', to_jsonb(coalesce(v_old, '{}')),
            'canadian_terms', app.staff_terms_canadian(coalesce(p -> 'extra', '{}'::jsonb))));
    -- the To do of 4 closes once nobody it listed still needs a new agreement
    if not exists (select 1 from staff_profiles sp where app.staff_agreement_needs_canada(sp.user_id)) then
      update tasks set status = 'done', completed_at = now(), completion_note = 'Every staff member in Canada has a new agreement'
       where task_type = 'staff_agreement_canada' and status in ('open', 'in_progress', 'waiting');
    end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.sign_request_create(uuid, jsonb)'::regprocedure, 'app.sign_request_create_pre2862(uuid, jsonb)'::regprocedure);
revoke all on function app.sign_request_create_pre2862(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.sign_request_create_pre2862(uuid, jsonb) to service_role;

-- ================================================================ 3. the Admin list
alter function app.staff_agreements(uuid) rename to staff_agreements_pre2862;
create function app.staff_agreements(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.e || jsonb_build_object(
           'needs_canada_terms', app.staff_agreement_needs_canada((x.e ->> 'user_id')::uuid),
           'superseded', (select jsonb_build_object('id', s.id, 'signed_at', s.signed_at, 'superseded_at', s.superseded_at) from sign_requests s
                           where s.staff_user_id = (x.e ->> 'user_id')::uuid and s.doc_type = 'staff_agreement' and s.superseded_at is not null
                           order by s.superseded_at desc limit 1)) order by x.o), '[]'::jsonb)
    from jsonb_array_elements(app.staff_agreements_pre2862(p_by)) with ordinality x(e, o)
$$;
select pg_temp.copy_grants('app.staff_agreements(uuid)'::regprocedure, 'app.staff_agreements_pre2862(uuid)'::regprocedure);
revoke all on function app.staff_agreements_pre2862(uuid) from public, anon, authenticated;
grant execute on function app.staff_agreements_pre2862(uuid) to service_role;

-- ================================================================ 4. the To do, once
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('staff_agreement_canada', 'admin', 'Send staff in Canada a new agreement with Canadian terms', 'high', 'none', null,
   'Release 45 (2862): these staff live in Canada but their agreement (waiting or signed) was made with the remote assistant terms (the Philippines, USD, OnlineJobs.ph). Settings > Staff, Staff agreements: press Send a new agreement beside each; it is filled with the Canadian terms.')
on conflict (task_type) do nothing;

do $$
declare
  v_names text;
  v_n integer;
begin
  select count(*), string_agg(coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email), ', ' order by u.full_name)
    into v_n, v_names
    from staff_profiles sp join users u on u.id = sp.user_id
   where app.staff_agreement_needs_canada(sp.user_id);
  if v_n > 0 then
    perform app.raise_task(p_type => 'staff_agreement_canada', p_queue => 'admin', p_priority => 'high',
      p_title => format('Send %s staff in Canada a new agreement with Canadian terms', v_n),
      p_detail => left(format('Their agreement says the Philippines, USD or OnlineJobs.ph: %s. Settings > Staff, Staff agreements: press Send a new agreement beside each (it is filled with Canada, CAD and Interac e-Transfer or direct deposit). A signed one stays on file as superseded.', v_names), 1000),
      p_dedupe => 'staff_agreement_canada:r45');
  end if;
end $$;

revoke all on function app.staff_terms_canadian(jsonb) from public, anon, authenticated;
grant execute on function app.staff_terms_canadian(jsonb) to service_role;
revoke all on function app.staff_current_agreement(uuid) from public, anon, authenticated;
grant execute on function app.staff_current_agreement(uuid) to service_role;
revoke all on function app.staff_agreement_needs_canada(uuid) from public, anon, authenticated;
grant execute on function app.staff_agreement_needs_canada(uuid) to service_role;
