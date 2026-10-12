export interface CheckoutRequest {
  bookingId: string;
  bookingNumber: string;
  amountCents: number;
  currency: 'cad';
  customerEmail: string;
  description: string;
  successUrl: string;
  cancelUrl: string;
  idempotencyKey: string;
}
export interface HoldRequest { bookingId: string; paymentMethodId: string; customerId: string; amountCents: number; idempotencyKey: string }
export interface PaymentRef { id: string; status: string; url?: string }

export interface PaymentsAdapter {
  readonly name: 'stripe' | 'fake';
  createCheckout(req: CheckoutRequest): Promise<PaymentRef>;
  placeHold(req: HoldRequest): Promise<PaymentRef>;
  captureHold(holdId: string, amountCents: number, idempotencyKey: string): Promise<PaymentRef>;
  releaseHold(holdId: string, idempotencyKey: string): Promise<PaymentRef>;
  refund(paymentId: string, amountCents: number, idempotencyKey: string): Promise<PaymentRef>;
}
