// Email is sent by the send-outbox Edge Function (docs/architecture.md section 5), never by a page.
// The app's part is to cause events in the database (app.emit_event), which fill notification_outbox.
// This interface is what that function's sender implements; it lives here so the contract is typed.
export interface OutgoingEmail { to: string; from: string; replyTo?: string; subject: string; html: string; text: string; idempotencyKey: string; headers?: Record<string, string> }
export interface EmailAdapter {
  readonly name: 'resend' | 'fake';
  send(m: OutgoingEmail): Promise<{ id: string }>;
}
