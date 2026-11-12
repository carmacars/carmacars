-- 2373_r38_field_agreements_unblock.sql (release 38)
-- Owner, Nov 11: field staff said their agreements were not live, so the onboarding gate held them. The Field Staff
-- Agreement required the driver's licence number, which no record holds, so the agreements job (1060) recorded every field
-- hire as waiting and retried only once a day. From r38 the address and licence number are optional (person-agreements
-- model: a blank reads as the profile address and the licence copy uploaded in the portal), so the agreement is generated
-- and sent by itself. This clears the waiting rows so the job sends every pending agreement on its next runs.
delete from staff_agreement_auto where request_id is null;
