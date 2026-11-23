// Stripe.js in the browser, loaded once from js.stripe.com (the card number never touches our pages): the Payment
// Element and confirmPayment, the two calls the card forms use. New card forms load it from here (3600: gift cards).
export interface StripeJs {
  elements(o: { clientSecret: string; appearance?: unknown }): { create(type: 'payment', o?: unknown): { mount(el: HTMLElement): void; destroy?(): void } };
  confirmPayment(o: { elements: unknown; redirect: 'if_required'; confirmParams: Record<string, unknown> }): Promise<{ error?: { message?: string }; paymentIntent?: { id: string; status: string } }>;
}

export function loadStripe(key: string): Promise<StripeJs> {
  const w = window as unknown as { Stripe?: (k: string) => StripeJs };
  return new Promise((resolve, reject) => {
    if (w.Stripe) return resolve(w.Stripe(key));
    const s = document.createElement('script');
    s.src = 'https://js.stripe.com/v3/';
    s.onload = () => (w.Stripe ? resolve(w.Stripe(key)) : reject(new Error('Stripe did not load')));
    s.onerror = () => reject(new Error('Stripe did not load'));
    document.head.appendChild(s);
  });
}

/** The Payment Element as every card form shows it: the brand's red, cards only, no wallets, Canada first. */
export function mountCard(js: StripeJs, clientSecret: string, el: HTMLElement): unknown {
  const elements = js.elements({ clientSecret, appearance: { theme: 'stripe', variables: { colorPrimary: '#D0111B', colorText: '#000000', borderRadius: '6px', fontFamily: 'Inter, Helvetica, Arial, sans-serif' } } });
  elements.create('payment', { layout: 'tabs', wallets: { applePay: 'never', googlePay: 'never' }, fields: { billingDetails: { name: 'never' } }, defaultValues: { billingDetails: { address: { country: 'CA' } } } }).mount(el);
  return elements;
}
