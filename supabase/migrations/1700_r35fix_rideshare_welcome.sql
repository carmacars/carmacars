-- 1700_r35fix_rideshare_welcome.sql
-- Release 35, fix helper, task 1 (docs/changes/2026-11-11-r35fix-owner-decisions.md). The owner, November 11, 2026:
-- "Ride-hailing and delivery work are allowed." Renters may use the car for rideshare (Uber, Lyft and similar) and for
-- delivery apps.
--   1. The rental agreement: a new version of the terms (docs/source/v2_rental.md, generated into the web app by
--      scripts/gen-agreement.mjs; the template version follows the text's hash, rental-v3-9a3b89d542). Section 10.2 no longer
--      prohibits ride-hailing and delivery work; a new 10.3 says "Rideshare and delivery driving are welcome"; Care becomes
--      10.4. Coverage, Damage, the mileage allowance and the other prohibited uses are unchanged. Agreements already signed
--      keep their own version and their signed PDF (rental_agreements.template_version, documents.sha256): nothing here
--      touches them.
--   2. The public FAQ (On the road): "Can I use the car for Uber, Lyft or delivery apps?" Yes, in the positive. The AI
--      auto-replies (2110) answer from the same FAQ. Added to the live block once; an Admin's own edits are kept.
-- The requirements page, the search-term pages and the rideshare documents request (1303, still under "More" on the
-- booking page) already said yes and are unchanged in the database.
-- No applied migration is edited.

update site_content_blocks b
   set data = jsonb_set(b.data, '{items}',
         (select jsonb_agg(x.item order by x.ord) from (
            select e.item, e.ord::numeric as ord from jsonb_array_elements(coalesce(b.data -> 'items', '[]'::jsonb)) with ordinality e(item, ord)
            union all
            select jsonb_build_object('question', 'Can I use the car for Uber, Lyft or delivery apps?',
                     'answer', 'Yes. Rideshare and delivery driving are welcome. Tell us in your request; once booked, your booking page makes the documents the platforms ask for. Your mileage allowance, coverage and the rest of the rental agreement apply as usual.'),
                   2.5) x)),
       updated_at = now()
 where b.block_key = 'faq.road' and b.kind = 'faq'
   and not (b.data::text ilike '%uber, lyft or delivery apps%');
