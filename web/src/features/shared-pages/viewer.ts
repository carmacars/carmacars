// r31 "Simple": one page per object for Admin and staff. The Admin and staff addresses render the same component tree;
// what a viewer sees and may press comes from these pure tables, so each staff function keeps exactly the data and the
// actions it had on its own copy, and an Admin keeps everything. The database still decides (admin_read, va_read and
// ops_read refuse what a function may not read); these tables only decide what the page shows.
// Pure: the pages, the unit tests and the access e2e read it.

export type StaffFn = 'finance' | 'fleet' | 'cs' | 'sales';
// r35 part X: field staff helping a renter on the spot (/staff/field/help) are a viewer of their own: payment, the deposit, the licence
// in person and the signature only (refunds and voids stay with Finance and Admin; the database checks each step again).
export type Viewer = { role: 'admin' } | { role: 'staff'; fn: StaffFn } | { role: 'field' };

export const ADMIN: Viewer = { role: 'admin' };
export const staffViewer = (fn: StaffFn): Viewer => ({ role: 'staff', fn });
export const FIELD: Viewer = { role: 'field' };

/** The portal the page is rendered in: its links stay in that portal (the staff layout gives the staff door to buttons). */
export function portalBase(v: Viewer): '/admin' | '/staff' {
  return v.role === 'admin' ? '/admin' : '/staff';
}

const fnOf = (v: Viewer): StaffFn | null => (v.role === 'staff' ? v.fn : null);

/** The booking page (`/admin/bookings/[number]`, `/staff/bookings/[number]`). */
export interface BookingCan {
  /** Admin-only parts: placeholder and calendar switches, cancel by CarmaCars, swap the car, insurer invoice and claim,
   * the price, sales credit and marketing source, the debit card switch, the pay plan, the full deposit, statements,
   * offers, status history, emails, documents, waive the deposit, withdraw an approved change. */
  admin: boolean;
  /** review the request, send, edit, withdraw or re-open the offer, ask the renter, decline */
  offer: boolean;
  /** Edit the offer while the renter pays (Sales only while it is still offered) */
  editOfferPending: boolean;
  /** the Money section */
  money: boolean;
  /** the Claims & extras section: changes, extensions, questions; Change the booking */
  extras: boolean;
  cancelForRenter: boolean;
  /** schedule a field job from the booking */
  scheduleJob: boolean;
  /** the late-return panel while the car is out past its time */
  latePanel: boolean;
  /** the photo review link (pickup and return side by side) */
  photoReview: boolean;
  handover: boolean;
  sign: boolean;
  /** the agreement panel's money lines */
  agreementMoney: boolean;
  /** the renter's licence card (Sales: the licence only, not the coverage) */
  licenceReview: boolean;
  /** the full renter documents card (licence, selfie and coverage) */
  renterDocs: boolean;
  /** the plain upload card (staff; an Admin uploads from the renter documents card) */
  staffUpload: boolean;
  /** a link to the car's page */
  carLink: boolean;
  /** record a payment received another way */
  manualPayments: boolean;
  /** correct or void a payment received another way, or a paper signature */
  voidRecords: boolean;
  /** upload a document signed on paper */
  paperSignatures: boolean;
  /** the additional drivers' signing links */
  driverLinks: boolean;
  /** ask for a refund (Finance: up to its limit, above it an Admin approves) */
  refund: boolean;
  /** approve a refund within the function's limit (Finance) */
  refundApprove: boolean;
  settleDeposit: boolean;
  /** issue the final statement after the return */
  statement: boolean;
  /** r35 gaps (2435/2437): the insurer claim and adjuster card, on insurer-billed bookings only (app.booking_insurer_save: Admin, CS, Finance) */
  insurerClaim: boolean;
  /** the texts inbox for the Text button */
  inbox: boolean;
  /** verify a driver in person */
  verifyInPerson: boolean;
  /** 0910: change the car before pickup (Sales on a request or an offer, Fleet on a confirmed booking; the database checks) */
  changeCar: boolean;
  /** r35 (0970): take payments only (pay links, the saved card, deposit holds, cash or e-Transfer for Finance to check);
   * never refunds or voids. Fleet's Money tab is this. */
  collectOnly: boolean;
  /** r35 (0970): mark the late car "returning now" (the renter's overdue reminders stop) */
  returningNow: boolean;
  /** r35 UX (1106): send the offer again with a later expiry */
  resendOffer: boolean;
  /** r35 UX (1106): the get-ready checklist (paid, identity, coverage, deposit, agreement, drivers, add-ons in the car) */
  readiness: boolean;
  /** r35 UX (1106): remove an add-on after booking (a paid one is refunded): never Sales */
  addonRemove: boolean;
  /** r35a (1300): the original request, the offer history and the coverage card (Admin, customer service, Sales, Fleet) */
  requestHistory: boolean;
}

export function bookingCan(v: Viewer): BookingCan {
  if (v.role === 'field') return fieldCan();
  const admin = v.role === 'admin';
  const fn = fnOf(v);
  const office = admin || fn === 'cs' || fn === 'sales';
  return {
    admin,
    offer: office,
    // r35 UX (1106): Sales gets a renter ready like customer service: the offer while it is paid, the licence, selfie and
    // coverage, the drivers' links, the checklist (refunds, cancellations and deposit settlements stay where they were)
    editOfferPending: admin || fn === 'cs' || fn === 'sales',
    // r35 (0970): Fleet collects payments (the database decides each tool: app.user_collects_money); refunds stay Finance
    money: office || fn === 'finance' || fn === 'fleet',
    extras: admin || fn === 'cs',
    cancelForRenter: admin || fn === 'cs',
    scheduleJob: fn === 'fleet',
    latePanel: fn === 'fleet' || fn === 'cs',
    photoReview: fn === 'fleet',
    handover: fn !== 'finance',
    sign: fn !== 'finance',
    agreementMoney: admin || fn === 'finance',
    licenceReview: false,
    renterDocs: admin || fn === 'sales',
    staffUpload: !admin,
    carLink: admin || fn === 'fleet' || fn === 'cs',
    manualPayments: admin || fn === 'finance' || fn === 'fleet',
    voidRecords: admin,
    paperSignatures: admin || fn === 'cs',
    driverLinks: admin || fn === 'cs' || fn === 'sales',
    refund: admin || fn === 'finance',
    refundApprove: fn === 'finance',
    settleDeposit: admin || fn === 'finance',
    statement: admin || fn === 'finance',
    // r35 (0970): Fleet texts and calls on its own lane
    inbox: office || fn === 'fleet',
    verifyInPerson: admin,
    changeCar: admin || fn === 'cs' || fn === 'fleet' || fn === 'sales',
    collectOnly: fn === 'fleet',
    returningNow: admin || fn === 'fleet' || fn === 'cs',
    resendOffer: office,
    readiness: office,
    addonRemove: admin || fn === 'cs' || fn === 'fleet' || fn === 'finance',
    requestHistory: admin || fn === 'cs' || fn === 'sales' || fn === 'fleet',
    insurerClaim: admin || fn === 'cs' || fn === 'finance'
  };
}

/** Field staff on the spot: collect payment and the deposit (pay link, QR, card reader), the licence in person, the signature
 *  (on the phone, the link, a paper photo by the existing rules). Nothing else. */
function fieldCan(): BookingCan {
  const no = { admin: false, offer: false, editOfferPending: false, money: false, extras: false, cancelForRenter: false, scheduleJob: false, latePanel: false, photoReview: false,
    handover: false, sign: false, agreementMoney: false, licenceReview: false, renterDocs: false, staffUpload: false, carLink: false, manualPayments: false, voidRecords: false,
    paperSignatures: false, driverLinks: false, refund: false, refundApprove: false, settleDeposit: false, statement: false, inbox: false, verifyInPerson: false, changeCar: false, collectOnly: false, returningNow: false,
    resendOffer: false, readiness: false, addonRemove: false, requestHistory: false, insurerClaim: false };
  return { ...no, money: true, handover: true, sign: true, paperSignatures: true, verifyInPerson: true };
}

/** The sections a viewer gets as tabs on the booking page. */
export function bookingTabs(v: Viewer): string[] {
  const c = bookingCan(v);
  return ['overview', 'money', 'documents', 'car', 'activity', 'extras'].filter((k) => (k !== 'money' || c.money) && (k !== 'extras' || c.extras));
}

/** The vehicle page (`/admin/vehicles/[id]`, `/staff/vehicles/[id]`). */
export interface VehicleCan {
  /** the full Admin car page: every tab, owner terms, fees, Revenue Share, status and retire */
  admin: boolean;
  /** Finance opens a car for its maintenance and bills only */
  maintenanceOnly: boolean;
  /** the car, its listing state and its documents */
  car: boolean;
  /** enter the rates (Fleet) */
  rates: boolean;
  /** the maintenance panel next to the car (Fleet) */
  maintenance: boolean;
  /** the owner's handoffs (Fleet) */
  ownerHandoffs: boolean;
  /** Publish now when the listing may go up */
  publish: boolean;
}

export function vehicleCan(v: Viewer): VehicleCan | null {
  if (v.role === 'field') return null;
  const admin = v.role === 'admin';
  const fn = fnOf(v);
  if (fn === 'sales') return null; // the staff vehicle page is for Fleet, customer service and Finance
  return {
    admin,
    maintenanceOnly: fn === 'finance',
    car: admin || fn === 'fleet' || fn === 'cs',
    rates: admin || fn === 'fleet',
    maintenance: admin || fn === 'fleet',
    ownerHandoffs: admin || fn === 'fleet',
    publish: admin || fn === 'fleet' || fn === 'cs'
  };
}

/** The listing review page (`/admin/listings/[id]`, `/staff/listings/[id]`). */
export interface ListingCan {
  /** Retry a failed listing and Unlist a published one */
  admin: boolean;
  /** the link to the car's page in the header */
  carLink: boolean;
  /** the sample photos note */
  samplesNote: boolean;
}

export function listingCan(v: Viewer): ListingCan | null {
  if (v.role === 'field') return null;
  const admin = v.role === 'admin';
  const fn = fnOf(v);
  if (!admin && fn !== 'cs' && fn !== 'fleet') return null; // the staff listing page is for customer service and Fleet
  return { admin, carLink: admin || fn === 'fleet', samplesNote: admin };
}

/**
 * The staff addresses that render the shared page (not a redirect: the staff layout gives the page the staff door, so
 * every button acts as the staff member, with their function's limits). Each maps to the Admin address of the same
 * page; `shared` names the component both render.
 */
export const STAFF_SHARED: Record<string, { admin: string; shared: string }> = {
  '/staff/bookings/[number]': { admin: '/admin/bookings/[number]', shared: 'features/booking-page/BookingPage' },
  '/staff/vehicles/[id]': { admin: '/admin/vehicles/[id]', shared: 'features/vehicle-page/VehiclePage' },
  '/staff/listings/[id]': { admin: '/admin/listings/[id]', shared: 'features/listing-page/ListingPage' },
  '/staff/requests': { admin: '/admin/requests', shared: 'features/requests-page/RequestsPage' },
  '/staff/bookings': { admin: '/admin/bookings', shared: 'features/bookings-page/BookingsPage' },
  '/staff/renters': { admin: '/admin/renters', shared: 'features/renters-page/RentersPage' },
  '/staff/owners/add-car': { admin: '/admin/owners/add-car', shared: 'features/add-owner-car-page/AddOwnerCarPage' },
  '/staff/listings/import-photos': { admin: '/admin/vehicles/import-photos', shared: 'features/drive-import/DriveImportPage' }
};
