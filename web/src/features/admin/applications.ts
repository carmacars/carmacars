// The owner applications inbox (migration 0054): the status chips, in plain words.
export const APP_STATUS: Record<string, string> = { new: 'New', waiting_on_owner: 'Waiting on owner', approved: 'Approved', declined: 'Declined', account_only: 'Account only: no car yet' };
export const CHECKS: Array<[string, string]> = [['licence', 'Driver\'s licence'], ['ownership', 'Ownership'], ['insurance', 'Insurance'], ['lender', 'Lender or lessor']];
export const CHECK_RESULT: Record<string, string> = { ok: 'Checked, fine', problem: 'Problem', not_needed: 'Not needed', not_checked: 'Not checked' };
