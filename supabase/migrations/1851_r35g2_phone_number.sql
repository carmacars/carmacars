-- r35 gaps: one phone number everywhere. Guide chapters (draft and published copy), message templates and academy lessons that carry the old digits (321) now carry 289-312-5991.
update guide_sections set
  body_md = replace(body_md, '289-321-5991', '289-312-5991'),
  published_md = replace(published_md, '289-321-5991', '289-312-5991'),
  published_html = replace(published_html, '289-321-5991', '289-312-5991')
where body_md like '%289-321-5991%' or published_md like '%289-321-5991%' or published_html like '%289-321-5991%';
update message_templates set body = replace(body, '289-321-5991', '289-312-5991') where body like '%289-321-5991%';
update academy_lessons set scenes = replace(scenes::text, '289-321-5991', '289-312-5991')::jsonb where scenes::text like '%289-321-5991%';
