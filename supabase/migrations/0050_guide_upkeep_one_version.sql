-- 0050_guide_upkeep_one_version.sql
-- Guide upkeep (0049): the run sends its changed screenshots one by one, and each raised the guide's version, so one run
-- took the Admin guide from version 3 to 35 on October 16. Now a guide gets one new version per run (its PDF still shows
-- as older until guides-pdf prints it again). The same function, replaced with the same signature; nothing else changes.
-- (docs/changes/2026-10-16-supply-manual-rentals-signing.md, section 7.)

create or replace function app.guide_upkeep_apply(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  img jsonb;
  s guide_sections;
  v_old text;
  v_new text;
  v_sections integer := 0;
  v_images integer := 0;
  v_portals text[] := '{}';
begin
  if jsonb_typeof(p -> 'images') is distinct from 'array' then raise exception 'No images' using errcode = '22023'; end if;
  for img in select value from jsonb_array_elements(p -> 'images') loop
    v_old := img ->> 'old_url'; v_new := img ->> 'new_url';
    if coalesce(v_old, '') !~ '^(/|https://)' or coalesce(v_new, '') !~ '^(/|https://)' or v_old = v_new then continue; end if;
    -- an image replaced before is found by its latest address
    insert into guide_images (portal, url, storage_key, alt, width, height, bytes, replaces_url)
    values (nullif(img ->> 'portal', ''), v_new, nullif(img ->> 'storage_key', ''), 'Screenshot retaken by the guide upkeep', nullif(img ->> 'width', '')::integer,
            nullif(img ->> 'height', '')::integer, nullif(img ->> 'bytes', '')::integer, v_old);
    v_images := v_images + 1;
    for s in select * from guide_sections x
              where position(v_old in x.body_md) > 0 or position(v_old in coalesce(x.published_md, '')) > 0 or position(v_old in coalesce(x.published_html, '')) > 0
              for update loop
      update guide_sections
         set body_md = replace(body_md, v_old, v_new),
             published_md = replace(published_md, v_old, v_new),
             published_html = replace(published_html, v_old, v_new),
             needs_review = true, review_flagged_at = now(),
             review_note = 'A screenshot in this section changed: check that the steps and labels still match it.',
             review_images = (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(s.review_images) e where e ->> 'new_url' <> v_new)
                             || jsonb_build_array(jsonb_build_object('old_url', v_old, 'new_url', v_new, 'diff', img -> 'diff', 'at', now(), 'run', p ->> 'run'))
       where id = s.id;
      if position(v_old in s.body_md) > 0 then
        insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
        values (s.id, s.draft_version, s.title, s.blurb, replace(s.body_md, v_old, v_new), s.is_hidden, false)
        on conflict (section_id, version, published) do update set body_md = excluded.body_md, saved_at = now();
      end if;
      if position(v_old in coalesce(s.published_html, '')) > 0 then v_portals := array_append(v_portals, s.portal); end if;
      v_sections := v_sections + 1;
    end loop;
  end loop;
  -- one new version per guide and run (the run sends its images one by one)
  update guides g set version = version + 1, published_at = now()
   where g.portal = any (v_portals) and g.version > 0
     and not exists (select 1 from audit_log l where l.action = 'guide_upkeep' and l.entity_id = coalesce(p ->> 'run', 'manual')
                       and l.at > now() - interval '1 day' and coalesce(l.after -> 'portals', '[]'::jsonb) ? g.portal);
  insert into audit_log (action, entity_table, entity_id, after)
  values ('guide_upkeep', 'guides', coalesce(p ->> 'run', 'manual'), jsonb_build_object('images', v_images, 'sections', v_sections, 'portals', to_jsonb(v_portals)));
  return jsonb_build_object('images', v_images, 'sections', v_sections, 'portals', to_jsonb((select array_agg(distinct x) from unnest(v_portals) x)));
end $$;
