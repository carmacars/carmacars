-- 5209 (R51 review fix 3): closing a team follow-up also needs app.manages(caller, member) at the time of the call.
-- A manager reassigned away from the member (or no longer a manager) cannot close the old follow-up. 5206 is not edited.
create or replace function app.team_followup_done(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  f team_followups;
  v_note text := left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 500);
begin
  select * into f from team_followups where id = nullif(p ->> 'id', '')::uuid for update;
  if f.id is null or f.manager_id <> p_user or not app.manages(p_user, f.member_id) then raise exception 'Not one of your follow-ups' using errcode = '42501'; end if;
  if not app.manager_section_passed(p_user) then raise exception 'Pass the Manager section of the academy first' using errcode = '55000'; end if;
  if f.status = 'done' then return jsonb_build_object('ok', true, 'repeat', true); end if;
  if v_note is null then raise exception 'Write what you agreed' using errcode = '22023'; end if;
  update team_followups set status = 'done', note = v_note, done_at = now(), done_by = p_user where id = f.id;
  return jsonb_build_object('ok', true);
end $$;
