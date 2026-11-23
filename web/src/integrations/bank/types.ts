// Release 49 (3480): a live bank feed (docs/finance/bank-data.md). Read only: balances and posted transactions, never a
// payment. Each feed's lines go through the same app.bank_import as a downloaded file, so dedupe and matching are the
// same. Credentials stay with the provider (an OAuth token or the provider's own consent screen), never in this app's
// database; provider_ref is only the provider's id of the account.
import type { BankLine } from '@/features/finance/bank-file';

export type BankProvider = 'file' | 'fake' | 'rbc_api' | 'flinks' | 'plaid' | 'cdb';
export interface FeedAccount { ref: string; last4: string; currency: 'CAD' | 'USD'; nickname: string }
export interface FeedBalance { balance_cents: number; available_cents: number | null; as_of: string }

export interface BankFeed {
  readonly provider: BankProvider;
  /** false: nothing is connected (the file import is the way in) */
  readonly connected: boolean;
  accounts(): Promise<FeedAccount[]>;
  balance(ref: string): Promise<FeedBalance>;
  /** posted transactions from a day (YYYY-MM-DD) to today, oldest first */
  transactions(ref: string, from: string): Promise<BankLine[]>;
}
