// Shared merge variables: one sample value each, plus a note for the engineer where the name is not obvious.
// An email uses a variable simply by writing {{name}} in its copy. The build reads the names from the template,
// takes the sample from here (or from the email's own "sample"), and lists them in catalogue.json.
//
// Conventions the application must follow when it fills a template:
//   Money   formatted, with the dollar sign: "$468.95". Canadian dollars.
//   Dates   "Fri, Oct 23, 2026". Times "10:00 am" (no periods, so a time can end a sentence). Always Toronto time.
//   Lists   arrays of objects; the fields are named in catalogue.json.
//   Flags   true or false.
//   Links   full https URLs. Signed file links must stay valid for at least 7 days.
const v = (sample, note) => (note ? { sample, note } : { sample });

export const SAMPLES = {
  // People
  first_name: v('Maya', 'First name of the person the email is addressed to.'),
  renter_name: v('Maya Okafor'),
  owner_name: v('Daniel Rossi'),
  staff_name: v('Jordan'),
  field_staff_name: v('Sam', 'First name of the field staff member doing the handover.'),

  // Booking
  booking_number: v('CC-10482', 'Agreement and booking number shown to the customer.'),
  vehicle_name: v('2024 Honda Civic Sport', 'Year, make, model and trim.'),
  vehicle_image_url: v('', 'Public listing photo, 1200px wide or more. Leave empty when there is none; the dark name block shows instead.'),
  vehicle_plate: v('CMCR 482'),
  pickup_date: v('Fri, Oct 23, 2026'),
  pickup_time: v('10:00 am'),
  pickup_place: v('Union Station, 65 Front Street West, Toronto'),
  return_date: v('Mon, Oct 26, 2026'),
  return_time: v('10:00 am'),
  return_place: v('Union Station, 65 Front Street West, Toronto'),
  billable_days: v('3', 'Billable days of the booking.'),
  km_allowance: v('600 km', 'Allowance per day times billable days.'),
  overage_rate: v('$0.35', 'Per extra kilometre, from the booking price snapshot.'),
  line_items: v([
    { label: 'Rental charge, 3 days', amount: '$340.00' },
    { label: 'Delivery', amount: '$75.00' },
    { label: 'HST (13%)', amount: '$53.95' },
  ], 'Booking lines in order, HST last. Each item: label, amount.'),
  total_amount: v('$468.95', 'Total due at booking, HST included.'),
  amount_paid: v('$468.95'),
  deposit_amount: v('$500.00', 'Security deposit for this booking, taken at pickup.'),
  card_last4: v('4242', 'Last four digits of the Card on File.'),
  card_brand: v('Visa'),
  roadside_phone: v('289-312-5991', 'The 24-hour roadside and incident line (site_settings.roadside_phone_display).'),

  vehicle_id: v('v-3f81c2', 'Vehicle id as used in portal URLs.'),
  renter_phone: v('416-555-0142'),

  // Money and documents
  amount: v('$126.50'),
  payment_date: v('Tue, Oct 20, 2026'),
  receipt_number: v('R-204817'),
  receipt_url: v('https://carmacars.ca/files/sample-receipt', 'Signed link to the receipt PDF.'),
  signed_agreement_url: v('https://carmacars.ca/files/sample-signed-agreement', 'Signed link to the signed agreement PDF.'),
  supporting_document_url: v('https://carmacars.ca/files/sample-supporting-record', 'Signed link to the supporting record: notice, photos, receipt or estimate.'),

  // Account
  review_url: v('https://carmacars.ca/review/3f8a2c9e-5b1d-4c7a-9e2f-6a1b0c4d8e7f', 'The renter\'s review page without sign-in (review_requests.token, 0138): what they liked, a sentence, the draft, Copy and Post on Google.'),
  review_done_url: v('https://carmacars.ca/review/3f8a2c9e-5b1d-4c7a-9e2f-6a1b0c4d8e7f?done=1', 'The same page asking to confirm "I already left a review" (stops the review requests).'),
  google_review_url: v('https://search.google.com/local/writereview?placeid=ChIJsample', 'The Google review form of the Business Profile (site_settings.google_place_id).'),
  reset_url: v('https://carmacars.ca/account/reset-password?token=sample', 'One-time link from the sign-in service.'),
  sign_in_url: v('https://carmacars.ca/account/sign-in?token=sample', 'One-time link from the sign-in service.'),
  link_expiry: v('60 minutes', 'How long the one-time link stays valid.'),
  unsubscribe_url: v('https://carmacars.ca/unsubscribe?token=sample', 'One-click unsubscribe link, tokenised per recipient. Also send it in the List-Unsubscribe header.'),

  // Program settings in words (0051): every email can use them; they follow Admin > Settings, never typed into the copy
  debit_day: v('15th', 'The owner debit day (program_settings.billing_day) as an ordinal.'),
  retry_day: v('18th', 'The retry day of a returned owner debit (program_settings.retry_day) as an ordinal.'),
  payout_day: v('10th', 'The owner payout day (program_settings.payout_day) as an ordinal.'),
  approve_by_day: v('9th', 'The day before the payout day, by which the Admins approve the statements.'),
  payee_name: v('18122211 Canada Inc., operating as CarmaCars', 'The payee of the pre-authorized debit as the emails name it (app.owner_email_payee_name, 0128): the legal name, operating as the business name, as the legal review approved (0053). The agreements name the company by its legal name alone (0122); an email never shows the numbered company alone. Named in every owner billing email.'),
  late_fee_rule: v('If your bank returns the automatic debit of an invoice for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.', 'The one Late Fee rule (app.owner_debit_terms): the same sentence in the PAD agreement, the Banking page and every owner billing email.'),
  arrears_removal_days: v('30', 'Days after a failed retry before CarmaCars may remove the vehicle (owner_arrears_removal_days).'),
  notice_period_days: v('30', 'The Notice Period of the Enrollment Agreement in days (notice_period_days).'),
  deductible_amount: v('$2,500.00', 'The fleet policy deductible (deductible_cents).'),
  safety_certificate_days: v('36', 'Days a safety certificate is valid (safety_certificate_days).'),
  retransfer_business_days: v('10', 'Business days to transfer the registration back after the Exit Date (retransfer_business_days).'),
  refund_days: v('10', 'Business days within which a refund is sent (refund_business_days).'),
  deposit_release_days: v('7', 'Business days after check-in within which the Deposit is released (deposit_release_business_days).'),
  holdback_days: v('30', 'Days after check-in within which a held-back Deposit is applied or released (deposit_holdback_days).'),
  min_renter_age: v('18', 'The minimum age of every driver (min_renter_age).'),
  id_retention_days: v('90', 'Days after the rental ends before licence images and selfies are deleted (retention_id_face_days).'),
  non_refundable_percent: v('10%', 'The non-refundable discount (non_refundable_discount_bps) as a percentage.'),
  incident_report_hours: v('48', 'Hours within which the renter sends the incident report (incident_report_hours).'),
  interest_after_days: v('7', 'Days after a statement before unpaid amounts carry interest (statement_interest_days).'),
};

// Sample values that differ by audience, so the previews read naturally.
export const AUDIENCE_SAMPLES = {
  owner: { first_name: 'Daniel', vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', vehicle_plate: 'CXRV 310' },
  investor: { first_name: 'Amira' },
  staff_admin: { first_name: 'Abbas' },
  staff_va_finance: { first_name: 'Grace' },
  staff_va_fleet: { first_name: 'Paolo' },
  staff_va_cs: { first_name: 'Jessa' },
  staff_va_sales: { first_name: 'Marco' },
  staff_field: { first_name: 'Sam' },
};
