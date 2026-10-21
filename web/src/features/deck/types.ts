// app.deck_figures() (migration 0078): every number the deck shows, from the database.
export interface DeckTier { min_vehicles: number; max_vehicles: number | null; insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; monthly_fees_cents: number }
export interface DeckSplit { kind: 'program_owner' | 'company' | 'partner'; label: string; share_bps: number; company_rental_cents: number; owner_cents: number; company_cents: number; monthly_fees_cents: number }
export interface DeckFigures {
  viewer: 'admin' | 'investor';
  investor_name?: string;
  settings: { show_to_investors: boolean; deck_multiplier: number | string; deck_return_bps: number; updated_at: string; updated_by: string | null };
  brand: { name: string; tagline: string | null; city: string | null; service_area: string | null; phone: string | null; phone_href: string | null; email: string | null; incident_phone: string | null; site_url: string | null };
  investment: { min_cents: number; lockup_months: number; redemption_notice_months: number; payment_day: number; election_notice_days: number };
  owner_tiers: DeckTier[];
  install_fee_cents: number | null;
  partner_commission_bps: number | null;
  deductible_cents: number | null;
  deposits: { min_cents: number | null; max_cents: number | null } | null;
  rates: { source: 'real' | 'default'; min_daily_cents: number | null; max_daily_cents: number | null; median_daily_cents: number; delivery_cents: number };
  addons: Array<{ name: string; unit: 'per_trip' | 'per_day' | 'per_hour'; price_cents: number; cap_cents: number | null }>;
  fees: Record<string, { amount_cents: number | null; percent_bps: number | null }> | null;
  emails: number;
  sample: { days: number; daily_rate_cents: number; rental_cents: number; delivery_cents: number; addon_name: string | null; addon_cents: number; young_driver_cents: number;
    company_only_cents: number; total_cents: number; splits: DeckSplit[] };
}
