// The signing session as the page sees it (migration 0154, app.esign_view): a rental agreement signature, and since 0181
// every other signature (documents in a portal, another Owner's link).
/** A document signed in a portal (0181): the owner's agreement or schedule ("packet", ref its key), a document sent to
 *  sign ("request", ref the sign_requests id), an updated Vehicle Schedule ("schedule_change", ref the change id). */
export interface EsignDoc { kind: 'packet' | 'request' | 'schedule_change'; ref: string; sha: string; title: string }
export type EsignContext =
  | { kind: 'renter'; number: string }
  | { kind: 'driver'; token: string }
  | { kind: 'in_person'; booking: string; signer: string }
  | { kind: 'amendment'; number: string; requestId: string }
  | { kind: 'version'; token: string; inPerson?: boolean }
  | { kind: 'documents'; docs: EsignDoc[]; role: 'owner' | 'partner' | 'investor' | 'staff' }
  | { kind: 'cosigner'; token: string };

export interface EsignView {
  id: string; context: string; signer_name: string; signer_role: string; method: 'remote' | 'in_person';
  channels: Array<{ channel: 'sms' | 'email'; to: string }>; code_sent_to: string | null; verified: boolean; viewed: boolean;
  required_initials: string[]; required_consents: string[]; initials: string[]; consents: string[]; signature: 'drawn' | 'typed' | null;
  typed_fallback_allowed: boolean; signed: boolean; ready: boolean;
  licence: { licence_front?: string | null; licence_back?: string | null; selfie?: string | null; verified?: boolean; expiry?: string | null; complete?: boolean } | null;
}

/** What the sign button sends once the session is ready. */
export interface EsignReady { session: string; method: 'drawn' | 'typed'; drawnPath?: string; typedName?: string }
