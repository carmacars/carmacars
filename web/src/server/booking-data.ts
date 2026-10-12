import 'server-only';
import { block, getFacts } from '@/lib/site';
import { legalValues } from '@/features/legal/render';
import type { RequestRules } from '@/features/booking/schema';

export async function rules(): Promise<RequestRules> {
  const f = await getFacts();
  return { minAge: f.min_renter_age, maxDays: f.max_rental_days, maxAdditional: f.max_additional_drivers, maxSeats: f.max_baby_seats, noteMax: f.request_note_max_chars, licenceClasses: [...f.accepted_licence_classes].sort(), otherLicence: f.other_licence_for_review, noticeMinutes: f.booking_min_notice_minutes };
}

/** The consent wording shown on the form, with its version: what is recorded is what was shown. */
export async function consentTexts() {
  const [meta, mk, v] = await Promise.all([block('legal.meta'), block('legal.marketing_opt_in'), legalValues()]);
  const version = String((meta?.data as { last_updated?: string } | undefined)?.last_updated ?? '');
  const strip = (h: string) => h.replace(/<[^>]+>/g, '');
  const marketing = (mk?.body ?? '').replace(/\{\{(\w+)\}\}/g, (_, k: string) => strip(v[k] ?? ''));
  return {
    terms: { version, text: 'I agree to the Terms of use.' },
    privacy: { version, text: 'I agree to the Privacy policy.' },
    agreeLine: (minAge: number) => `I am ${minAge} or older, the details above are true, and I agree to the Terms of use and Privacy policy.`,
    marketing: { version: String((mk?.data as { version?: string } | undefined)?.version ?? version), text: marketing }
  };
}

