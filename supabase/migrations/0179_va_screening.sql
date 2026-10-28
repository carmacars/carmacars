-- 0179: the VA roles' screening, schedule and calls (docs/changes/2026-10-28-va-screening.md).
--
-- The owner (October 28, 2026): VA interviews are 10 minutes, back to back, on Saturday; the screening asks about the
-- internet connection, English, social media skills, their skills and experience, their understanding of the role and of
-- CarmaCars, their agreement to the hours and the pay, other jobs, school, education, career or job, and moving to
-- Canada; every VA who does not pass goes to Sales (remote). Customer service starts at 9:00 and fleet at 11:00 Toronto
-- time, 6 days a week, 10 hours a day; fleet is a full operations role. Pay is monthly (US$400, US$450, US$200 part time).
-- No paid test for the VA roles (the owner, October 28): the call, then the decision. SCHEMA_MARKER 0179.

create or replace function pg_temp.yes_no(p_key text, p_label text, p_yes text, p_no text, p_pts int, p_ko_reason text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'label', p_label, 'type', 'single', 'ko_reason', p_ko_reason, 'choices', jsonb_build_array(
    jsonb_build_object('v', p_yes, 'pts', p_pts), jsonb_build_object('v', p_no, 'pts', 0, 'ko', true)))
$$;

-- The questions every VA role asks, around the role's own: its schedule, pay, tools and scenario.
create or replace function pg_temp.va_screen(p_schedule text, p_pay text, p_years text, p_tools jsonb, p_scenario jsonb) returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    -- the hours and the pay (a no is a knock-out)
    pg_temp.yes_no('schedule', p_schedule, 'Yes, I can work this schedule every week', 'No', 15, 'the schedule of the role'),
    pg_temp.yes_no('pay', p_pay, 'Yes, I accept this pay', 'No', 10, 'the pay of the role'),
    -- internet and power
    jsonb_build_object('key', 'internet', 'label', 'What is your internet connection where you will work?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Fiber or cable, 25 Mbps or faster, plus a backup connection', 'pts', 15),
      jsonb_build_object('v', 'Fiber or cable, 25 Mbps or faster, no backup', 'pts', 8),
      jsonb_build_object('v', 'Slower than 25 Mbps, or mobile data only', 'pts', 0))),
    jsonb_build_object('key', 'speed', 'label', 'Your latest speed test (download and upload, in Mbps)', 'type', 'text', 'placeholder', 'For example 80 down, 40 up'),
    jsonb_build_object('key', 'backup', 'label', 'What is your backup if the power goes out?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'A generator, inverter or power station', 'pts', 5), jsonb_build_object('v', 'Laptop battery only', 'pts', 2), jsonb_build_object('v', 'None', 'pts', 0))),
    -- English
    jsonb_build_object('key', 'english', 'label', 'How is your spoken English with North American customers?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Fluent: I handle calls on my own every day', 'pts', 15), jsonb_build_object('v', 'Good: I can handle most calls', 'pts', 8),
      jsonb_build_object('v', 'Basic: I am more comfortable in writing', 'pts', 0))),
    -- experience and skills
    jsonb_build_object('key', 'years', 'label', p_years, 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Under 1 year', 'pts', 0), jsonb_build_object('v', '1 to 2 years', 'pts', 5), jsonb_build_object('v', '2 to 4 years', 'pts', 12), jsonb_build_object('v', '5 years or more', 'pts', 15))),
    jsonb_build_object('key', 'experience', 'label', 'Describe your most relevant job: the company, what you did every day, and for how long.', 'type', 'para',
      'score', jsonb_build_object('min_words', 30, 'pts', 10)),
    jsonb_build_object('key', 'tools', 'label', 'Which of these have you used for work?', 'type', 'multi', 'hint', 'Choose all that apply.', 'required', false, 'choices', p_tools,
      'score', jsonb_build_object('each', 2, 'max', 10)),
    jsonb_build_object('key', 'social', 'label', 'Which social media and listing work have you done for a business?', 'type', 'multi', 'hint', 'Choose all that apply.', 'required', false,
      'choices', jsonb_build_array('Posting on Facebook Marketplace', 'Posting in Facebook groups', 'Instagram posts and stories', 'TikTok videos', 'Replying to messages and comments for a business', 'Designing posts in Canva', 'Posting on classified sites (Kijiji, Craigslist or similar)'),
      'score', jsonb_build_object('each', 2, 'max', 10)),
    jsonb_build_object('key', 'skills', 'label', 'What are you best at? Tell us your three strongest skills for this role.', 'type', 'para'),
    -- understanding of the role and of CarmaCars
    jsonb_build_object('key', 'business', 'label', 'What does CarmaCars do?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Sells used cars', 'pts', 0), jsonb_build_object('v', 'Rents cars to customers in Toronto', 'pts', 10),
      jsonb_build_object('v', 'Repairs cars', 'pts', 0), jsonb_build_object('v', 'A ride-hailing app', 'pts', 0))),
    jsonb_build_object('key', 'role', 'label', 'In your own words, what will you do on a normal shift in this role?', 'type', 'para', 'score', jsonb_build_object('min_words', 30, 'pts', 10)),
    p_scenario,
    -- other work, school, education, plans
    jsonb_build_object('key', 'other_jobs', 'label', 'Will you work other jobs or clients alongside this role?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'No, this would be my only job', 'pts', 10), jsonb_build_object('v', 'Yes, part time, outside these hours', 'pts', 4),
      jsonb_build_object('v', 'Yes, during these hours', 'pts', 0))),
    jsonb_build_object('key', 'clients', 'label', 'Is any of your other jobs or clients a vehicle rental business?', 'type', 'single', 'ko_reason', 'no work for another car rental business serving Ontario',
      'choices', jsonb_build_array(jsonb_build_object('v', 'No', 'pts', 0), jsonb_build_object('v', 'Yes, one serving Ontario', 'pts', 0, 'ko', true))),
    jsonb_build_object('key', 'school', 'label', 'Are you studying right now?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'No', 'pts', 5), jsonb_build_object('v', 'Yes, with classes outside these hours', 'pts', 2), jsonb_build_object('v', 'Yes, with classes during these hours', 'pts', 0))),
    jsonb_build_object('key', 'education', 'label', 'Your highest education', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'High school', 'pts', 0), jsonb_build_object('v', 'Some college', 'pts', 2), jsonb_build_object('v', 'College degree', 'pts', 4), jsonb_build_object('v', 'Postgraduate', 'pts', 4))),
    jsonb_build_object('key', 'education_detail', 'label', 'School and course (or field of study)', 'type', 'text', 'required', false),
    jsonb_build_object('key', 'career', 'label', 'Are you looking for a long-term career or a short-term job?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'A long-term career, growing with one company', 'pts', 10), jsonb_build_object('v', 'A job for now', 'pts', 0))),
    jsonb_build_object('key', 'canada', 'label', 'Would you like to move to Canada one day?', 'type', 'single', 'choices', jsonb_build_array(
      jsonb_build_object('v', 'Yes', 'pts', 0), jsonb_build_object('v', 'Maybe', 'pts', 0), jsonb_build_object('v', 'No', 'pts', 0))),
    jsonb_build_object('key', 'start', 'label', 'Earliest start date', 'type', 'date'))
$$;

-- The 10-minute call, back to back.
create or replace function pg_temp.va_call(p_role text) returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_array('0:00 to 1:00', 'Introduce yourself and CarmaCars. Confirm the role, the pay and the schedule (Toronto time).'),
    jsonb_build_array('1:00 to 3:00', 'Walk me through a normal day in your last job. Good: specific tasks, tools and volumes; clear spoken English.'),
    jsonb_build_array('3:00 to 6:00', p_role),
    jsonb_build_array('6:00 to 8:00', 'Other jobs, school, internet and power backup, start date. Career or job? Good: this is their main job, real backup, a long-term plan.'),
    jsonb_build_array('8:00 to 9:00', 'Tell me back in one sentence what CarmaCars does and what this role does. Good: right on both, without reading.'),
    jsonb_build_array('9:00 to 10:00', 'Their questions. Next step: we decide within two days and write to everyone.'))
$$;

update hiring_roles set
  title = 'Customer Service Coordinator (Remote)',
  summary = 'Be the first reply every renter gets: calls, texts, WhatsApp, email and website chat within 15 minutes, quotes and offers, follow-ups and licence checks. Full time from 9:00 am Toronto time.',
  details = $j${"about":"CarmaCars is a Toronto car rental company. You are the first reply every renter gets: fast, accurate and friendly, on our portal, phone line, WhatsApp, email and website chat.",
    "duties":["Answer every call, text, WhatsApp, email and website chat within 15 minutes","Turn enquiries into quotes from our rate sheet and send booking offers","Follow up on unpaid offers and on people who started a booking and stopped","Check driver's licences and insurance coverage before pickup; chase renters for missing details","Handle extension and cancellation requests and questions during a rental","In quiet hours: post our cars on Facebook Marketplace and classified sites, and reach out to car owners who may list with us"],
    "requirements":["Two years of phone and chat support for North American customers","Clear, neutral spoken English","Accurate quoting under time pressure; you follow scripts and never invent a discount","Your own computer, headset, backup internet and power","No work for another car rental business serving Ontario"],
    "hours":"Full time: 6 days a week, 10 hours a day, starting 9:00 am Toronto time (night in Manila), weekends included. Independent contractor, 30-day paid trial.",
    "test_task":null}$j$::jsonb,
  pay_text = 'US$400 a month, full time: 6 days a week, 10 hours a day', pay_currency = 'USD', pay_min_cents = 40000, pay_max_cents = 40000, pay_unit = 'MONTH',
  employment_types = '{CONTRACTOR,FULL_TIME}', refer_on = 'below_or_ko', refer_to = '{sales-remote}', refer_alt = null,
  questions = pg_temp.va_screen(
    'This role is full time: 6 days a week, 10 hours a day, starting 9:00 am Toronto time (night in Manila), weekends included. Can you work this schedule?',
    'The pay is US$400 a month. Do you accept this pay?',
    'Years of phone and chat support for North American customers',
    '["Zendesk, Freshdesk or another help desk","WhatsApp Business","A CRM (HubSpot, Salesforce or similar)","Google Workspace","A VoIP phone system"]'::jsonb,
    '{"key":"scenario","label":"Three chats and a call arrive together. What do you do?","type":"single","choices":[{"v":"Answer the call and let the chats wait until it ends","pts":0},{"v":"Reply only to the newest chat","pts":0},{"v":"Acknowledge every one inside 15 minutes, use the templates and log each","pts":10}]}'::jsonb),
  call_guide = jsonb_build_object('steps', pg_temp.va_call('One of the customer service questions below.'), 'questions', $j$[
    ["Three chats and a call arrive together.","Acknowledges all inside 15 minutes; uses templates; logs each."],
    ["A renter wants 15% off and to drive to Quebec.","No promise; escalates to Admin; keeps the hold."]]$j$::jsonb),
  updated_at = now()
 where slug = 'va-customer-service';

update hiring_roles set
  title = 'Fleet Operations Coordinator (Remote)',
  summary = 'A full operations role: dispatch field staff, prepare the paperwork and complete every rental agreement, review photos, handle late returns, tows and parts, and cover customer service. Full time from 11:00 am Toronto time.',
  details = $j${"about":"CarmaCars is a Toronto car rental company. This is a full operations role: you keep every car, rental and field staff member on schedule, and nothing goes out the door unfinished.",
    "duties":["Build the day's schedule and dispatch our field staff for deliveries, pickups, returns and cleaning; confirm every job is done","Prepare the paperwork for each rental and make sure every rental agreement is complete in full before a car is handed over","Review pickup and return photos within an hour for damage, kilometres and fuel, and pass findings to billing the same day","Watch return times and GPS trackers; chase late returns and handle breakdowns and roadside calls","Dispatch tow trucks when needed","Source parts for maintenance and repairs, and book cars into the shop","Keep each car's status accurate (on rent, cleaning, in the shop)","Take over customer service calls and messages when needed","Before you finish each shift, list all the work needed for the next day"],
    "requirements":["Two years in operations, dispatch or logistics for a foreign client (car rental, automotive or fleet experience is a plus)","Organized and detail-oriented: paperwork done right, photos checked properly","Calm on the phone in an emergency; clear spoken English","Your own computer, headset, backup internet and power","No work for another car rental business serving Ontario"],
    "hours":"Full time: 6 days a week, 10 hours a day, starting 11:00 am Toronto time (night in Manila), weekends included. Independent contractor, 30-day paid trial.",
    "test_task":null}$j$::jsonb,
  pay_text = 'US$450 a month, full time: 6 days a week, 10 hours a day', pay_currency = 'USD', pay_min_cents = 45000, pay_max_cents = 45000, pay_unit = 'MONTH',
  employment_types = '{CONTRACTOR,FULL_TIME}', refer_on = 'below_or_ko', refer_to = '{sales-remote}', refer_alt = null,
  questions = pg_temp.va_screen(
    'This role is full time: 6 days a week, 10 hours a day, starting 11:00 am Toronto time (night in Manila), weekends included. Can you work this schedule?',
    'The pay is US$450 a month. Do you accept this pay?',
    'Years in operations, dispatch or logistics for a foreign client',
    '["A dispatch or routing tool","GPS or fleet tracking","Google Sheets or Excel","Photo or damage inspection apps","A ticketing or task system","A VoIP phone system"]'::jsonb,
    '{"key":"scenario","label":"Two pickups today: one driver is not answering and one car''s tracker is offline. What do you do?","type":"single","choices":[{"v":"Release both cars so the renters are not kept waiting","pts":0},{"v":"Cancel both bookings","pts":0},{"v":"Apply the tracker and release rules first, escalate to the office and release nothing unverified","pts":10}]}'::jsonb),
  call_guide = jsonb_build_object('steps', pg_temp.va_call('One of the fleet questions below.'), 'questions', $j$[
    ["Two pickups today, one driver silent, one tracker offline.","Tracker and release rules first; escalates; releases nothing unverified."],
    ["A car breaks down on the highway with a renter inside.","Safety first; dispatches a tow; arranges a replacement; logs it."]]$j$::jsonb),
  updated_at = now()
 where slug = 'va-fleet-operations';

update hiring_roles set
  summary = 'Run our billing: price post-rental charges, settle deposits, match tolls to bookings, bill car owners and build owner statements and payouts. Part time, 4 days a week.',
  details = jsonb_set(details, '{hours}', to_jsonb('Part time: 4 days a week, 9 hours a day, Toronto daytime (night in Manila), plus the 1st, 10th and 15th of each month. Independent contractor, 30-day paid trial.'::text)) || '{"test_task":null}'::jsonb,
  pay_text = 'US$200 a month, part time: 4 days a week, 9 hours a day', pay_currency = 'USD', pay_min_cents = 20000, pay_max_cents = 20000, pay_unit = 'MONTH',
  refer_on = 'below_or_ko', refer_to = '{sales-remote}', refer_alt = null,
  questions = pg_temp.va_screen(
    'This role is part time: 4 days a week, 9 hours a day, Toronto daytime (night in Manila), plus the 1st, 10th and 15th of each month. Can you work this schedule?',
    'The pay is US$200 a month. Do you accept this pay?',
    'Years of bookkeeping or billing for a foreign client',
    '["Excel or Google Sheets (formulas, lookups)","QuickBooks","Xero","Stripe","Bank reconciliation","Wise or PayPal"]'::jsonb,
    '{"key":"scenario","label":"An owner emails new bank details the day before payout. What do you do?","type":"single","choices":[{"v":"Update the details and pay on time","pts":0},{"v":"Hold the payout without telling anyone","pts":0},{"v":"Change nothing, verify by a phone number we already have and wait for written approval","pts":10}]}'::jsonb),
  call_guide = jsonb_build_object('steps', pg_temp.va_call('One of the finance questions below.'), 'questions', $j$[
    ["An owner emails new bank details the day before payout.","Changes nothing; verifies by a known phone number; waits for written approval."],
    ["A statement is off by $3.40. What do you do?","Finds the exact line before sending; never rounds it away."]]$j$::jsonb),
  updated_at = now()
 where slug = 'va-finance-billing';

-- No paid test in any role (the owner, October 28): the call, then the decision.
update hiring_roles set details = details || '{"test_task":null}'::jsonb,
       call_guide = replace(call_guide::text, 'Next step: the paid test task, then our decision.', 'Next step: we decide within two days and write to everyone.')::jsonb,
       updated_at = now()
 where details ->> 'test_task' is not null or call_guide::text like '%paid test%';
