-- 5042 (release 50): Amazon SES is out of its sandbox (production access granted: 50,000 emails a day in ca-central-1,
-- carmacars.ca verified). Email follows each message type's channel (email_production_ready, 2971), and SES may send up
-- to 5,000 a day before Resend takes over (email_ses_daily_max was the sandbox's 200). docs/email-providers.md step 6.
-- SCHEMA_MARKER 5042.
update program_settings set email_production_ready = true,
  email_ses_daily_max = greatest(email_ses_daily_max, 5000)
 where not email_production_ready or email_ses_daily_max < 5000;
