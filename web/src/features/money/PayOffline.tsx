import type { CardPayments } from './card-pay';

// r50 hotfix2 (5110): how to pay without a card, on every invoice and pay page: Interac e-Transfer to the Program setting's
// address and, when the account is set (cc_pay_*), direct deposit. Server rendered; the values come from
// app.card_payments_state, never from code.
export function PayOffline({ card, reference, amount, title = 'Pay by e-Transfer or direct deposit', testId = 'pay-offline' }: {
  card: Pick<CardPayments, 'e_transfer_email' | 'direct_deposit'> | null | undefined; reference: string; amount?: string | null; title?: string; testId?: string;
}) {
  const dd = card?.direct_deposit ?? null;
  return (
    <section className="pt-card stack" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <h2 className="d4" id={`${testId}-h`}>{title}</h2>
      <dl className="pt-dl">
        <div><dt>Interac e-Transfer to</dt><dd><b data-testid={`${testId}-email`}>{card?.e_transfer_email ?? 'the email on your invoice'}</b></dd></div>
        <div><dt>Message</dt><dd><b>{reference}</b></dd></div>
        {amount ? <div><dt>Amount</dt><dd><b className="num">{amount}</b></dd></div> : null}
      </dl>
      {dd && (
        <>
          <p className="small">Or by direct deposit (bank transfer), with <b>{reference}</b> as the reference:</p>
          <dl className="pt-dl" data-testid={`${testId}-deposit`}>
            {dd.account_name ? <div><dt>Account name</dt><dd>{dd.account_name}</dd></div> : null}
            {dd.bank ? <div><dt>Bank</dt><dd>{dd.bank}</dd></div> : null}
            <div><dt>Institution</dt><dd className="num">{dd.institution}</dd></div>
            <div><dt>Transit</dt><dd className="num">{dd.transit}</dd></div>
            <div><dt>Account</dt><dd className="num">{dd.account}</dd></div>
          </dl>
        </>
      )}
      <p className="small muted">We mark it paid when it arrives, usually the same business day. Cash is welcome at pickup.</p>
    </section>
  );
}
