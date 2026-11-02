-- 0481: the words of 0480 wherever they live in the database (docs/changes/2026-11-07-extend-offers.md): the late fee
-- of 17.5% of the daily rate (at least $25) and the self-serve extension in the academy lessons and quiz, the public
-- FAQ, and the renter's end-of-booking texts with the offer line ({{extend_offer}}). Copy an
-- Admin changed is left as it is (each update matches the text as it was shipped). The email templates are loaded by
-- the deploy from emails/ (renter_return_soon and renter_return_due carry {{extend_offer}}).
-- No applied migration is edited.

-- ================================================================ the academy (Admin > Academy), as shipped by 0208
update academy_lessons set scenes = replace(replace(replace(replace(scenes::text,
    'After it, a late return costs 25 dollars an hour. A renter running late should ask to extend before their return time.',
    'After it, a late return costs 17.5 percent of the daily rate an hour, at least 25 dollars. A renter running late extends in their booking at a discount, even after the return time while they still have the car.'),
    '["After that", "$25 an hour"]', '["After that", "17.5% of the daily rate an hour, at least $25"]'),
    'After a 30 minute grace it is $25 an hour. If you need longer, I can extend the booking now so it is not a late return.',
    'After a 30 minute grace the late fee is 17.5% of the daily rate an hour, at least $25. Extend in your booking instead: it costs less, and it is approved at once when the car is free.'),
    'A renter running late should ask to extend before the return time. Approve the extension if the car is free, and remind them to pay before the current return.',
    'A renter running late can extend in their booking, even after the return time while they still have the car. Most extensions are approved at once; a request that comes to you: approve it if the car is free, and remind them to pay.')::jsonb
 where scenes::text like '%25 dollars an hour%' or scenes::text like '%$25 an hour%' or scenes::text like '%remind them to pay before the current return%';
update academy_lessons set scenes = replace(replace(scenes::text,
    'A renter who wants more time asks to extend before the return time, and pays for the extension before the current return.',
    'A renter who wants more time extends in their booking: 1 hour to 1 month, approved at once when the car is free, paid with the card on file. It works before the return time, and after it while they still have the car.'),
    '["Ask before the return time", "We approve", "Pay before the current return"]',
    '["Pick 1 hour to 1 month", "Approved at once when the car is free", "Pay with the card on file"]')::jsonb
 where scenes::text like '%asks to extend before the return time%';
update academy_questions set
    options = replace(options::text, '"$25 an hour after a 30 minute grace"', '"17.5% of the daily rate an hour (at least $25) after a 30 minute grace"')::jsonb,
    explain = replace(explain, 'There is a 30 minute grace, then $25 an hour.', 'There is a 30 minute grace, then 17.5% of the daily rate an hour, at least $25.')
 where options::text like '%$25 an hour after a 30 minute grace%';

-- ================================================================ the public FAQ (seeded from web/scripts/content/site-content.json)
update site_content_blocks set data = replace(replace(data::text,
    'plus a late fee of {{lateHr}} an hour counted from the return time. If you know you will be late, ask for an extension first.',
    'plus a late fee of {{lateHr}} for each started hour, counted from the return time. If you will be late, extend in your booking instead: it costs less, and you can do it even after the return time while you still have the car.'),
    'Ask before your return time. An extension counts only when we confirm it in writing and you have paid for it. The whole booking is repriced at its new length and you pay the difference.',
    'Yes, in your booking: pick 1 hour, 3 hours, 1 day, 3 days, 1 week or 1 month and pay with your card on file. A day or more is {{extDisc}} off the regular rate, and a few hours are {{extShortDisc}} off the late fee. It is approved at once when the car is free, and counts once it is paid. You can still extend after the return time while you have the car.')::jsonb,
    updated_at = now()
 where kind = 'faq' and (data::text like '%{{lateHr}} an hour counted from the return time%' or data::text like '%The whole booking is repriced at its new length and you pay the difference.%');

-- ================================================================ the texts: the offer line ("Extend at 5% off: from $X for 1 more day")
update sms_templates set body = 'CarmaCars: booking {{booking_number}} ends at {{return_time}}. Please return it to {{return_place}} with the same fuel, clean and with all keys. {{extend_offer}}: {{link}}', updated_at = now()
 where code = 'renter_return_soon'
   and body = 'CarmaCars: booking {{booking_number}} ends at {{return_time}}. Please return it to {{return_place}} with the same fuel, clean and with all keys. Need more time? Extend: {{link}}';
update sms_templates set body = 'CarmaCars: your booking {{booking_number}} ended at {{return_time}}. Please return the {{vehicle_name}} now. {{extend_offer}}: {{link}}', updated_at = now()
 where code = 'renter_return_due'
   and body = 'CarmaCars: your booking {{booking_number}} ended at {{return_time}}. Please return the {{vehicle_name}} now, or extend here if you need more time: {{link}}';
update notification_catalogue set variables = variables || '[{"name": "extend_offer", "type": "string"}]'::jsonb, updated_at = now()
 where code in ('renter_return_soon', 'renter_return_due') and not variables @> '[{"name": "extend_offer"}]'::jsonb;
