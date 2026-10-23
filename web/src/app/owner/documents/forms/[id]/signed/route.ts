import { NextResponse } from 'next/server';

// An official ServiceOntario form is printed and signed in ink (0120, the owner's rule of October 23, 2026: the forms
// stay exactly as published, only their empty text boxes are filled). It is no longer signed on screen; a form signed
// on paper is recorded by an Admin (Record paper signature) and filed at the registry.
export const dynamic = 'force-dynamic';
export async function POST() {
  return NextResponse.json({ ok: false, message: 'Official ServiceOntario forms are printed and signed in ink, not on screen.' }, { status: 410 });
}
