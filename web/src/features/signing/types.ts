// The signing session of a rental agreement signature as the page sees it (migration 0143, app.esign_view).
export type EsignContext =
  | { kind: 'renter'; number: string }
  | { kind: 'driver'; token: string }
  | { kind: 'in_person'; booking: string; signer: string }
  | { kind: 'amendment'; number: string; requestId: string }
  | { kind: 'version'; token: string; inPerson?: boolean };

export interface EsignView {
  id: string; context: string; signer_name: string; signer_role: string; method: 'remote' | 'in_person';
  channels: Array<{ channel: 'sms' | 'email'; to: string }>; code_sent_to: string | null; verified: boolean; viewed: boolean;
  required_initials: string[]; required_consents: string[]; initials: string[]; consents: string[]; signature: 'drawn' | 'typed' | null;
  typed_fallback_allowed: boolean; signed: boolean; ready: boolean;
  licence: { licence_front?: string | null; licence_back?: string | null; selfie?: string | null; verified?: boolean; expiry?: string | null; complete?: boolean } | null;
}

/** What the sign button sends once the session is ready. */
export interface EsignReady { session: string; method: 'drawn' | 'typed'; drawnPath?: string; typedName?: string }
