-- 3072 (release 48 integration): the tip link is in the text of the return too, not only in the email (the channel policy,
-- 2971, decides which of the two the renter gets; both now carry it). An Admin's own wording is kept: the line is added once,
-- and only where the text has room (a text that is already long is left as the Admin wrote it).
update sms_templates set body = body || ' Add a tip: https://carmacars.ca/account/bookings/{{booking_number}}/tip', updated_at = now()
 where code = 'renter_return_complete'
   and strpos(body, '/tip') = 0 and length(body) <= 270;
