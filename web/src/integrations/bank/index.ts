import 'server-only';
import type { BankFeed, BankProvider } from './types';

// The feed of Program setting bank_data_provider. Only the fake exists until a bank or an aggregator is connected
// (docs/finance/bank-data.md, "the path chosen"); every other value answers "not connected", and the file import stays
// the way in. The fake loads only where it is used (engineering rules: fakes never reach the production Worker).
const none = (provider: BankProvider): BankFeed => {
  const no = async (): Promise<never> => { throw new Error(provider === 'file' ? 'No bank feed is connected: import the CSV or OFX download.' : `The ${provider} bank feed is not connected yet: import the CSV or OFX download.`); };
  return { provider, connected: false, accounts: no, balance: no, transactions: no };
};

export async function bankFeed(provider: BankProvider): Promise<BankFeed> {
  if (provider === 'fake') return (await import('./fake')).fakeBank();
  return none(provider);
}
