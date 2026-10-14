-- 0039_statement_pdf_without_sign_in.sql
-- Found by the live run of the statement emails (docs/changes/2026-10-14-owner-debit.md, section 7): the PDF of an
-- approved owner statement could not be made for an owner on file who has no sign-in yet (0032's facts read the
-- statement as the owner's account, and there is none), so the statement email of such an owner never went. The
-- server (the statement emails job and the signed 7-day link, which pass no reader) now reads an approved statement
-- as the server does, through 0021's breakdown with an Admin as the reader. A signed-in person still reads only what
-- app.file_access lets them. No earlier migration is edited.
set local check_function_bodies = off;

alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_0037;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_reader uuid := p_user;
begin
  if p_kind = 'owner_statement' and p_user is null
     and exists (select 1 from owner_statements s join owners o on o.id = s.owner_id
                  where s.id = app.file_key_id(p_key) and s.status in ('approved', 'paid') and o.user_id is null) then
    select u.id into v_reader from users u join user_roles r on r.user_id = u.id and r.role = 'admin'
     where u.status = 'active' order by u.created_at limit 1;
  end if;
  return app.pdf_facts_0037(p_kind, p_key, v_reader);
end $$;

do $$
declare
  g text;
begin
  revoke execute on function app.pdf_facts(text, text, uuid) from public, anon, authenticated;
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.pdf_facts_0037(text, text, uuid)', 'execute') then
      execute format('grant execute on function app.pdf_facts(text, text, uuid) to %I', g);
    end if;
  end loop;
end $$;
