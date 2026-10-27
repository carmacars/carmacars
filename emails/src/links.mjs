// Every link an email may contain. Nothing else is allowed in an href (emails/check.mjs enforces it).
//
// Two kinds:
//   1. A path on carmacars.ca, listed in PATHS below. A path may carry merge variables for ids.
//   2. A pure merge variable, for links the server signs or tokenises (verify, reset, unsubscribe,
//      one-time offer link, signed file links). Those are declared per email in `variables`.
//
// The web team must serve every path in PATHS. Paths that need sign-in should send the person to
// sign-in and then back to the same path.

export const SITE = 'https://carmacars.ca';

export const PATHS = {
  // Public site
  home: '/',
  cars: '/cars',
  terms: '/terms',
  privacy: '/privacy',
  cancellation_policy: '/terms#cancellation',
  list_your_car: '/list-your-car',
  careers: '/careers',

  // Renter portal
  booking: '/account/bookings/{{booking_number}}',
  booking_messages: '/account/bookings/{{booking_number}}#messages',
  booking_offer: '/account/bookings/{{booking_number}}/offer',
  booking_request: '/account/bookings/{{booking_number}}/request',
  booking_agreement: '/account/bookings/{{booking_number}}/agreement',
  booking_sign: '/account/bookings/{{booking_number}}/sign',
  booking_verify: '/account/bookings/{{booking_number}}/verify',
  booking_pickup: '/account/bookings/{{booking_number}}/pickup',
  booking_condition_report: '/account/bookings/{{booking_number}}/condition-report',
  booking_return: '/account/bookings/{{booking_number}}/return',
  booking_extend: '/account/bookings/{{booking_number}}/extend',
  booking_change: '/account/bookings/{{booking_number}}/change',
  booking_statement: '/account/bookings/{{booking_number}}/statement',
  booking_pay: '/account/bookings/{{booking_number}}/pay',
  booking_incident: '/account/bookings/{{booking_number}}/incident',
  booking_review: '/account/bookings/{{booking_number}}/review',
  agreement_version_sign: '/sign/agreement/{{sign_token}}',

  // Owner portal
  owner: '/owner',
  owner_application: '/owner/application',
  owner_agreements: '/owner/agreements',
  owner_billing: '/owner/billing',
  owner_banking: '/owner/banking',
  owner_documents: '/owner/documents',
  owner_vehicle: '/owner/vehicles/{{vehicle_id}}',
  owner_vehicle_onboarding: '/owner/vehicles/{{vehicle_id}}/onboarding',
  owner_vehicle_calendar: '/owner/vehicles/{{vehicle_id}}/calendar',
  owner_vehicle_exit: '/owner/vehicles/{{vehicle_id}}/exit',
  owner_booking: '/owner/bookings/{{booking_number}}',
  owner_invoice: '/owner/invoices/{{invoice_number}}',
  owner_invoices: '/owner/invoices',
  owner_review: '/owner/review',
  owner_schedule_sign: '/owner/sign/schedule/{{change_id}}',
  owner_statement: '/owner/statements/{{statement_number}}',
  owner_claim: '/owner/claims/{{incident_number}}',
  owner_cosign: '/sign/owner/{{token}}',

  // Admin portal
  admin: '/admin',
  admin_approvals: '/admin/approvals',
  admin_statements: '/admin/statements',
  admin_payouts: '/admin/payouts',
  admin_dispute: '/admin/disputes/{{dispute_id}}',
  admin_incident: '/admin/incidents/{{incident_number}}',
  admin_fleet: '/admin/fleet',
  admin_jobs: '/admin/jobs',
  admin_weekly: '/admin/reports/weekly',
  admin_reports: '/admin/reports',
  admin_debits: '/admin/debits',
  admin_usage: '/admin/settings/usage',

  // VA portal
  va_cs: '/va/cs',
  va_cs_booking: '/va/cs/bookings/{{booking_number}}',
  va_cs_identity: '/va/cs/bookings/{{booking_number}}/identity',
  va_cs_reviews: '/va/cs/reviews',
  va_finance: '/va/finance',
  va_finance_booking: '/va/finance/bookings/{{booking_number}}',
  va_finance_toll: '/va/finance/tolls-tickets/{{toll_ticket_id}}',
  va_finance_invoice: '/va/finance/owner-invoices/{{invoice_number}}',
  va_finance_insurer_invoice: '/va/finance/insurer-invoices/{{invoice_number}}',
  va_fleet: '/va/fleet',
  va_fleet_booking: '/va/fleet/bookings/{{booking_number}}',
  va_fleet_listing: '/va/fleet/listings/{{vehicle_id}}',
  va_fleet_expiries: '/va/fleet/expiries',
  va_fleet_vehicle: '/va/fleet/vehicles/{{vehicle_id}}',
  va_sales: '/va/sales',
  va_sales_application: '/va/sales/applications/{{application_id}}',
  va_similar_cars: '/va/similar-cars',
  va_owner_forms: '/va/owner-forms',

  // Field portal
  field: '/field',
  field_job: '/field/jobs/{{job_id}}',
};

export function url(name) {
  if (!Object.prototype.hasOwnProperty.call(PATHS, name)) throw new Error('Unknown link: ' + name + '. Add it to src/links.mjs.');
  return SITE + PATHS[name];
}

// All absolute URLs, for the checker.
export function allUrls() {
  return Object.values(PATHS).map((p) => SITE + p);
}
