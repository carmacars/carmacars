-- 2515_r40_go_live_settings.sql
-- Release 40 goes live with: (1) the AI auto-replies back on every channel now that they are few, labelled as AI and kept to
-- basic, clear questions (faq.ts: 1 a day per sender, 90% sure or more); (2) the referral partner's sourced-by share
-- the owner set on Nov 12 (10% of that partner's referred rentals, before tax). Both apply to the current settings row /
-- the one partner only; a database without them (tests) is unchanged.
update program_settings
   set auto_reply_sms = true, auto_reply_email = true, auto_reply_whatsapp = true,
       auto_reply_messenger = true, auto_reply_instagram = true,
       auto_reply_per_sender_day = least(auto_reply_per_sender_day, 1),
       auto_reply_min_confidence_bps = greatest(auto_reply_min_confidence_bps, 9000)
 where id = (app.settings()).id;

update referral_partners
   set sourced_by = '93132b50-6d65-48b8-9f6c-d70400d2becb', sourced_by_bps = 1000
 where id = '425b58f0-2879-491f-b56f-dae6aec76d46'
   and sourced_by is null
   and exists (select 1 from users u where u.id = '93132b50-6d65-48b8-9f6c-d70400d2becb');
