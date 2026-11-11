-- 2251: no week of grace for the new academy sections (owner, Nov 11 2026: every staff member is locked out until they
-- finish the new academy training, sign the staff agreement and confirm the WhatsApp groups). 2151 (and 0932, 1040 before
-- it) gave staff who had passed their whole path a week before new sections hold them: that week ends now. Nothing else
-- changes: the onboarding gate (1151) already holds the agreement and WhatsApp steps, existing staff included.
update academy_enrollments set lock_from = now() where gate and lock_from > now();
