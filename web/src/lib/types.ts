// Shapes of what the public database functions return (0022, 0025, 0027). The functions are the
// contract; these types describe their JSON.

export interface Photo { path: string; variants: { width: number; path: string; format?: string }[]; alt: string; width?: number; height?: number; shot?: string; label?: string; is_cover?: boolean }

export interface CarRow {
  vehicle_id: string; slug: string; path: string; canonical_path: string; headline: string | null;
  year: number; make: string; model: string; trim: string | null; colour: string | null; fuel: string;
  class: string; classes: string[]; body_style: string | null; seats: number | null; transmission: string | null;
  doors: number | null; drivetrain: string | null; luggage: string | null; home_area: string | null;
  allows_18_to_20: boolean; is_featured: boolean; taking_requests: boolean; model_hub_path: string;
  daily_rate_cents: number; weekend_rate_cents: number; weekly_rate_cents: number; monthly_rate_cents: number;
  km_allowance_per_day: number; overage_cents_per_km: number; deposit_cents: number;
  delivery_fee_cents: number; pickup_fee_cents: number; cover: Photo | null; published_at: string | null; updated_at: string | null;
}

export interface CarPage extends CarRow {
  description: string | null; features: string[]; faq: { question: string; answer: string }[];
  specs: Record<string, unknown>; seo_title: string | null; seo_description: string | null; indexable: boolean; photos: Photo[];
}

export interface SiteSettings {
  brand_name: string; tagline: string | null; site_url: string; city: string; region: string; service_area: string;
  logo: { alt: string; dark: string | null; light: string | null; width: number | null; height: number | null; wordmark: string };
  favicon: string | null; og_image: string | null; phone: string | null; phone_display: string | null; whatsapp: string | null;
  whatsapp_display: string | null; roadside_phone: string | null; roadside_phone_display: string | null;
  public_email: string | null; owners_email: string | null; street_address: string | null; mailing_address: string | null;
  opening_hours_text: string | null; reply_wording: string | null; social_links: Record<string, string>;
  google_place_id: string | null; hst_number: string | null; listing_time_promise: string | null; featured_mode: string;
  seo: { title_suffix: string | null; default_title: string | null; default_description: string | null };
  airport_delivery: boolean | null; delivery_area_text: string | null;
}

export interface Fee { label: string; unit: string; amount_cents: number | null; cap_cents: number | null; percent_bps: number | null; grace_minutes: number | null }

export interface SiteFacts {
  hst_bps: number; max_rental_days: number; weekly_from_days: number; min_renter_age: number; standard_min_age: number;
  booking_min_notice_minutes: number; turnaround_buffer_minutes: number; take_deposit_lead_minutes: number;
  deposit_hold_max_days: number; deposit_release_business_days: number; deposit_holdback_days: number; refund_business_days: number;
  offer_expiry_hours: number; verification_due_hours_before_pickup: number; accepted_licence_classes: string[];
  other_licence_for_review: boolean; max_additional_drivers: number; max_baby_seats: number; request_note_max_chars: number;
  deductible_cents: number; non_refundable_discount_bps: number; damage_late_report_hours: number; incident_report_hours: number;
  payout_day: number; billing_day: number; notice_period_days: number; kickback_bps: number; install_fee_cents: number;
  delivery_per_km_cents: number; privacy_officer_name: string | null; privacy_officer_email: string | null;
  company_email: string | null; incident_line_phone: string | null;
  young_driver_bands: { code: string; from_age: number; to_age: number }[];
  fees: Record<string, Fee>; deposit_tiers_cents: number[]; km_choices: number[];
  email_aliases: Record<string, string>; airports: { code: string; name: string; surcharge_cents: number | null }[];
  cancellation: { grace_hours: number; grace_bps: number; early_hours: number; early_bps: number; late_hours: number; mid_bps: number; late_bps: number };
}

export interface ContentBlock { key: string; page: string; kind: 'text' | 'rich_text' | 'faq' | 'list'; body: string | null; data: Record<string, unknown> }
export interface FaqItem { question: string; answer: string }
export interface SlotPhoto { alt: string; wide: { path: string; width: number; height: number }; tall: { path: string; width: number; height: number } }
export interface CookieWording { version: string; title: string; text: string; accept: string; necessary: string; prefs: string; save: string; groups: { code: string; name: string; always: boolean; text: string }[] }
