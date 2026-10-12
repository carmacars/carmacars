// The owner application as the wizard holds it (form_drafts.data, form code "owner_application").
// Licence numbers are never kept in a draft (the database removes them on write); they are asked
// again after a resume. Everything is checked again by the database on submit.
export interface ApplyVehicle {
  key: string;
  vin: string; year: string; make: string; model: string; trim: string; colour: string; fuel: string; plate: string; odometer_km: string;
  current_insurer: string; branded: '' | 'no' | 'yes'; damage: '' | 'no' | 'yes'; damage_details: string;
  held_by: '' | 'individual' | 'corporation'; title_status: '' | 'owned_outright' | 'financed' | 'leased';
  finance_party_name: string; finance_party_account: string; finance_permission: '' | 'attached' | 'not_obtained' | 'proceed';
  management_mode: '' | 'managed' | 'self_managed' | 'turo_only'; onboarding_method: string; owners_lien: '' | 'elect' | 'decline';
  new_corporation_name: string; decoded: boolean;
}
export interface ApplyOwner {
  owner_type: '' | 'individual' | 'corporation'; first_name: string; middle_name: string; last_name: string;
  corporation_name: string; corporation_number: string; signing_officer_name: string; signing_officer_title: string;
  address: string; address_line1: string; address_line2: string; city: string; province: string; postal_code: string;
  email: string; phone: string; hst_number: string; licence_number: string; date_of_birth: string; referred_by: string;
}
export interface ApplyState { step: number; owner: ApplyOwner; vehicles: ApplyVehicle[]; active: number }

export const blankVehicle = (key: string): ApplyVehicle => ({
  key, vin: '', year: '', make: '', model: '', trim: '', colour: '', fuel: '', plate: '', odometer_km: '', current_insurer: '', branded: '', damage: '', damage_details: '',
  held_by: '', title_status: '', finance_party_name: '', finance_party_account: '', finance_permission: '', management_mode: 'managed', onboarding_method: '', owners_lien: '',
  new_corporation_name: '', decoded: false
});
export const blankOwner = (): ApplyOwner => ({
  owner_type: '', first_name: '', middle_name: '', last_name: '', corporation_name: '', corporation_number: '', signing_officer_name: '', signing_officer_title: '',
  address: '', address_line1: '', address_line2: '', city: '', province: 'ON', postal_code: '', email: '', phone: '', hst_number: '', licence_number: '', date_of_birth: '', referred_by: ''
});
export const DRAFT_COOKIE = 'cc-owner-draft';
export const STEPS = ['About you', 'Your vehicles', 'How it will work', 'Review and submit'] as const;

const VIN = /^[A-HJ-NPR-Z0-9]{17}$/;
export const cleanVin = (v: string) => v.toUpperCase().replace(/[\s-]/g, '');
const POSTAL = /^[A-Z]\d[A-Z] ?\d[A-Z]\d$/i;

export function ownerErrors(o: ApplyOwner): Record<string, string> {
  const e: Record<string, string> = {};
  if (!o.owner_type) e.owner_type = 'Choose an individual or a corporation.';
  if (!o.first_name.trim()) e.first_name = 'Enter your first name as on your licence.';
  if (!o.last_name.trim()) e.last_name = 'Enter your last name as on your licence.';
  if (o.owner_type === 'corporation') {
    if (!o.corporation_name.trim()) e.corporation_name = 'Enter the corporation\'s name.';
    if (!o.corporation_number.trim()) e.corporation_number = 'Enter the corporation number.';
    if (!o.signing_officer_title.trim()) e.signing_officer_title = 'Enter your title, for example Director.';
  }
  if (!o.address_line1.trim()) e.address_line1 = 'Enter the street address.';
  if (!o.city.trim()) e.city = 'Enter the city.';
  if (!POSTAL.test(o.postal_code.trim())) e.postal_code = 'A postal code looks like M5V 1A1.';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(o.email.trim())) e.email = 'Enter your email address.';
  if (o.phone.replace(/\D/g, '').length < 10) e.phone = 'Enter your phone number, for example 647-555-0142.';
  if (o.hst_number.trim() && !/^\d{9}RT\d{4}$/i.test(o.hst_number.replace(/\s/g, ''))) e.hst_number = 'An HST number looks like 123456789RT0001.';
  if (o.owner_type === 'individual') {
    if (!/^[A-Z]\d{4}-?\d{5}-?\d{5}$/i.test(o.licence_number.replace(/\s/g, ''))) e.licence_number = 'An Ontario licence number looks like A1234-12345-12345.';
    if (!/^\d{4}-\d{2}-\d{2}$/.test(o.date_of_birth)) e.date_of_birth = 'Enter your date of birth.';
  }
  return e;
}

export function vehicleErrors(v: ApplyVehicle, ownerType: ApplyOwner['owner_type']): Record<string, string> {
  const e: Record<string, string> = {};
  if (!VIN.test(cleanVin(v.vin))) e.vin = 'The VIN is 17 letters and numbers (no I, O or Q). It is on the ownership permit and the driver\'s door frame.';
  if (!/^(19[89]\d|20\d\d)$/.test(v.year)) e.year = 'Enter the year.';
  if (!v.make.trim()) e.make = 'Enter the make.';
  if (!v.model.trim()) e.model = 'Enter the model.';
  if (!v.colour.trim()) e.colour = 'Enter the colour.';
  if (!v.fuel) e.fuel = 'Choose the fuel.';
  if (!/^[A-Z0-9 ]{2,8}$/i.test(v.plate.trim())) e.plate = 'Enter the plate as on the permit.';
  if (!/^\d{1,6}$/.test(v.odometer_km.replace(/[\s,]/g, ''))) e.odometer_km = 'Enter the kilometres on the odometer.';
  if (!v.current_insurer.trim()) e.current_insurer = 'Enter your insurer.';
  if (!v.branded) e.branded = 'Answer this question.';
  if (!v.damage) e.damage = 'Answer this question.';
  if (v.damage === 'yes' && v.damage_details.trim().length < 5) e.damage_details = 'Tell us what it was.';
  if (!v.held_by) e.held_by = 'Choose who holds the ownership.';
  if (v.held_by === 'corporation' && ownerType !== 'corporation') e.held_by = 'Enrol as a corporation in step 1 to add a vehicle your corporation holds.';
  if (!v.title_status) e.title_status = 'Choose one.';
  if (v.title_status && v.title_status !== 'owned_outright' && !v.finance_party_name.trim()) e.finance_party_name = `Enter the ${v.title_status === 'leased' ? 'lease company' : 'lender'}.`;
  return e;
}

export function planErrors(v: ApplyVehicle): Record<string, string> {
  const e: Record<string, string> = {};
  if (!v.management_mode) e.management_mode = 'Choose how you want it rented.';
  if (v.management_mode !== 'turo_only' && !v.onboarding_method) e.onboarding_method = 'Choose a method.';
  if (v.title_status && v.title_status !== 'owned_outright' && !v.finance_permission) e.finance_permission = 'Answer this question.';
  if (v.onboarding_method === 'lease_new_owner_corporation' && !v.new_corporation_name.trim()) e.new_corporation_name = 'Enter the proposed name, or "numbered".';
  return e;
}

/** The vehicle as app.add_owner_vehicle reads it. */
export function vehiclePayload(v: ApplyVehicle) {
  return {
    vin: cleanVin(v.vin), plate: v.plate.toUpperCase().replace(/\s/g, ''), year: Number(v.year), make: v.make.trim(), model: v.model.trim(), trim: v.trim.trim() || null,
    colour: v.colour.trim(), fuel: v.fuel, odometer_km: Number(v.odometer_km.replace(/[\s,]/g, '')), current_insurer: v.current_insurer.trim(),
    title_brand_clear: v.branded !== 'yes', disclosures: { damage: v.damage === 'yes', details: v.damage_details.trim() || null },
    held_by: v.held_by, title_status: v.title_status, finance_party_name: v.title_status === 'owned_outright' ? null : v.finance_party_name.trim(),
    finance_party_account: v.finance_party_account.trim() || null,
    finance_permission: v.title_status === 'owned_outright' ? 'not_applicable' : v.finance_permission === 'attached' ? 'attached' : 'not_obtained',
    management_mode: v.management_mode || 'managed', onboarding_method: v.management_mode === 'turo_only' ? 'none' : v.onboarding_method || null,
    owners_lien: v.owners_lien === 'elect',
    new_corporation: v.onboarding_method === 'lease_new_owner_corporation' ? { proposed_name: v.new_corporation_name.trim() } : null
  };
}
