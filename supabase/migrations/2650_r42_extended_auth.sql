-- 2650_r42_extended_auth.sql
-- Release 42 (docs/changes/2026-11-12-r42-extended-auth.md). Stripe approved Extended Authorization on the live account:
-- a card hold can last up to about 30 days on Visa, Mastercard, Amex and Discover cards (not Interac). Program settings,
-- "Extended deposit holds" (0541, off until Stripe confirmed), is now on, for every dated row and for a new install.
-- Every deposit hold then asks Stripe for the longer hold "if available" and keeps the standard hold (about 7 days) where
-- the card does not allow it: the pay link and the staff device (createStaffIntent), the saved card on the pickup day and
-- Re-authorize (chargeOffSession, 0541), the card reader (r35). The hold's real expiry is still Stripe's capture_before
-- (public.server_deposit_hold_expiry, 0541), and a hold is still re-authorized before it lapses. Never on a rental charge.
-- No function changes: public.server_deposit_extended_holds (0541, the server's only) reads the setting.
alter table program_settings alter column deposit_extended_holds set default true;
update program_settings set deposit_extended_holds = true where not deposit_extended_holds;
comment on column program_settings.deposit_extended_holds is 'Extended deposit holds (0541; on since 2650, Stripe approved the account): every deposit hold asks Stripe for an extended authorization (up to about 30 days on Visa, Mastercard, Amex and Discover), falling back to a standard hold. Never on the rental charge.';
