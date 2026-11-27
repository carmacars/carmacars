-- 5163_r50h2_keyword_pages.sql
-- Release 50 hotfix 2: the landing page the keyword research found missing (docs/seo/keywords-2026-11.md): renting with
-- your own auto policy, the OPCF 27 endorsement. People in Ontario search "OPCF 27", "OPCF 27 rental car" and "does my car
-- insurance cover a rental in Ontario"; CarmaCars accepts it as coverage option 1 (1401: the pink slip and the endorsement
-- page uploaded before payment) and no page said so. Facts only from what the platform does; {{city}} and {{brand}} are
-- filled from the settings. A seed page, published, like 3232's; the writer may rewrite it from its searches (2640).
insert into seo_pages (slug, kind, name, sort_order, facts, match, copy, source, status) values
  ('opcf-27', 'use', 'Car rental with your own insurance (OPCF 27)', 245, '{"topic": "renting with your own auto policy and the OPCF 27 endorsement", "nearby": ["insurance-included", "insurance-replacement", "monthly"]}', '{}',
   jsonb_build_object('seo_title', 'OPCF 27 Rental Car Coverage in {{city}}: Rent With Your Own Policy | {{brand}}',
     'meta_description', 'Rent a car in {{city}} on your own Ontario auto policy with the OPCF 27 endorsement. Upload the pink slip and the endorsement page, and we check them before you pay.',
     'h1', 'Rent a car with your own insurance: OPCF 27',
     'intro', 'If your Ontario auto policy has the OPCF 27 endorsement, you can use it to cover the rental car itself at {{brand}}. Liability is already in every rate. Choose OPCF 27 as your coverage when you book, upload your pink slip and the endorsement page, and a person checks them before you pay.',
     'sections', jsonb_build_array(
       jsonb_build_object('heading', 'What OPCF 27 is', 'body', 'OPCF 27 is an Ontario endorsement to your own auto policy, Liability for Damage to Non-Owned Automobiles. It extends your policy to a car you rent or borrow, up to the limit and with the deductible your policy shows. Your insurer or broker adds it to your policy. Ask them for the endorsement page.'),
       jsonb_build_object('heading', 'What we need from you', 'body', 'Two pages: your pink slip (the liability card) and the OPCF 27 endorsement page, both current for the dates of the rental and in the name of the driver. Upload them on your booking. The booking is paid and confirmed once both are in and checked.'),
       jsonb_build_object('heading', 'If you do not have OPCF 27', 'body', 'You have two other ways to cover the car: the rental coverage of a credit card you pay with, or the {{brand}} Protection Plan, added to the booking. Compare the three on the requirements page before you choose.'),
       jsonb_build_object('heading', 'When your own car is in the shop', 'body', 'If your car is being repaired after a claim, your insurer may pay for a replacement rental directly. Ask your adjuster, and see insurance replacement rentals.')),
     'faq', jsonb_build_array(
       jsonb_build_object('question', 'Does my Ontario car insurance cover a rental car?', 'answer', 'Every {{brand}} rate includes liability. Damage to the rental car itself is covered by your policy only if it has the OPCF 27 endorsement. Check your policy or ask your broker.'),
       jsonb_build_object('question', 'Can I rent with OPCF 27 at {{brand}}?', 'answer', 'Yes. Choose OPCF 27 as your coverage, upload your pink slip and the endorsement page, and we check them before the booking is paid.'),
       jsonb_build_object('question', 'What if my OPCF 27 limit is lower than the value of the car?', 'answer', 'The endorsement covers up to its limit. Choose a car within it, or use the Protection Plan or your credit card''s coverage instead.'),
       jsonb_build_object('question', 'Do I still pay a deposit with OPCF 27?', 'answer', 'The coverage you choose does not change the deposit. Each car''s page shows its deposit, which is released after the return checks.'))), 'seed', 'published')
on conflict (slug) do nothing;
