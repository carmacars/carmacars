-- 99: "alternative" search terms on the place pages (migration 0522): Turo, RideAlike and Luup alternatives are rental
-- terms of their own (no synonym), active, in the sitemap files, with the not-affiliated sentence in the note and in a
-- question, nothing said about the other company, and the quality gate applying to them like every rental term.
select test.suite('99 seo alternatives');

select test.eq('three alternative terms, active, rental, served, none a synonym',
  (select count(*) from place_terms where slug in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')
      and is_active and vertical = 'rental' and served = 'yes' and canonical_slug is null), 3::bigint);
select test.eq('the titles the pages use ("<title> in <place>")',
  (select string_agg(title, ' | ' order by sort_order) from place_terms where slug like '%-alternative' and slug in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')),
  'Turo Alternative | RideAlike Alternative | Luup Alternative for Rideshare Drivers');
select test.ok('every note says CarmaCars is not affiliated with the company named',
  (select bool_and(intent_note ~ ('not affiliated with, approved or endorsed by ' || case slug when 'turo-alternative' then 'Turo' when 'ridealike-alternative' then 'RideAlike' else 'any of them' end))
     from place_terms where slug in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')));
select test.ok('and the first question answers it', (select bool_and(faq -> 0 ->> 'answer' like 'No. CarmaCars is not affiliated%') from place_terms
  where slug in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')));
select test.ok('nothing about the other company''s prices, fees or service (no comparison claims)',
  not exists (select 1 from place_terms where slug in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')
               and (intent_note || faq::text) ~* '(cheaper|better than|unlike|their (fees|prices|hosts|service)|lower than)'));
select test.ok('no other term says the same words (the duplicate rule: each intent its own note)',
  not exists (select 1 from place_terms a join place_terms b on b.slug <> a.slug and b.intent_note = a.intent_note
               where a.slug in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')));
select test.eq('in the sitemap files, one family per term',
  (select count(distinct f ->> 'term') from jsonb_array_elements(public.place_sitemap_files()) f
    where f ->> 'term' in ('turo-alternative', 'ridealike-alternative', 'luup-alternative')), 3::bigint);
