// r48: the name of an optional email in Notifications > Email preferences. The catalogue's subject is a template
// ("{{discount_percent}}% off your next CarmaCars rental"), so it is never shown as it is: a plain name for the known
// codes, otherwise the subject with every merge tag taken out. Pure: the preferences and the unit test read it.
const NAMES: Record<string, string> = {
  renter_comeback_1w: 'A discount a week after your rental',
  renter_comeback_1m: 'A discount a month after your rental',
  renter_promo_expiry_3d: 'Your discount code ends in 3 days',
  renter_promo_expiry_1d: 'Your discount code ends tomorrow',
  renter_review_request: 'Asking for your review',
  renter_review_preask: 'How was your trip',
  renter_review_ask: 'Asking for your review',
  renter_review_reminder: 'A reminder to review your trip',
  renter_review_final: 'A last reminder to review your trip',
  renter_google_review_request: 'A review on Google',
  renter_recovery_request: 'We are sorry: an offer to make it right',
  marketing_weekly: 'Weekly cars and offers',
  marketing_new_vehicle: 'New cars',
  renter_rewards_near_tier: 'Rewards: close to your next tier',
  renter_rewards_waiting: 'Rewards: your points are waiting',
  renter_rewards_statement: 'Rewards: your monthly points',
  renter_rewards_birthday: 'Rewards: your birthday reward',
  renter_rewards_holiday: 'Rewards: holiday rewards',
  // 3321: tracker events (the notice about a charge is always sent and is not listed)
  renter_driving_notice: 'A heads-up about your driving (no charge)',
  owner_tracker_alert: 'Tracker alert on your car',
};

/** a text with every {{tag}} (and its {{#if}} sections' tags) taken out, the spaces and punctuation left tidy */
export function noTags(s: string | null | undefined): string {
  return String(s ?? '').replace(/\{\{[^}]*\}\}%?/g, '').replace(/\s+([,.:;!?])/g, '$1').replace(/\s{2,}/g, ' ').replace(/^[\s,.:;]+/, '').replace(/[\s,:;]+$/, '').trim();
}

export function prefLabel(code: string, subject: string | null | undefined): string {
  return NAMES[code] ?? (noTags(subject) || code.replace(/_/g, ' '));
}
