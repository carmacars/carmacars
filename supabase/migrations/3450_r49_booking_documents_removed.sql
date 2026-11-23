-- r49: a booking's Documents tab listed documents that were removed or replaced (soft removal, 0821: removed_at), and
-- opening one gave a 404. The booking record's document list now leaves out removed documents. app.admin_booking_detail is
-- wrapped (_pre3450); no applied migration is edited.
set local check_function_bodies = off;

alter function app.admin_booking_detail(uuid) rename to admin_booking_detail_pre3450;
create function app.admin_booking_detail(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.admin_booking_detail_pre3450(p_booking);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at) order by d.created_at)
                                                         from documents d where d.booking_id = p_booking and d.purged_at is null and d.removed_at is null), '[]'::jsonb));
end $$;

do $$
declare g text;
begin
  revoke all on function app.admin_booking_detail(uuid) from public, anon, authenticated;
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.admin_booking_detail_pre3450(uuid)'::regprocedure, 'execute') then execute format('grant execute on function app.admin_booking_detail(uuid) to %I', g); end if;
  end loop;
end $$;
revoke all on function app.admin_booking_detail_pre3450(uuid) from public, anon, authenticated;
grant execute on function app.admin_booking_detail_pre3450(uuid) to service_role;
