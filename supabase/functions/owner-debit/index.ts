// owner-debit: the automatic monthly owner debit (docs/changes/2026-10-14-owner-debit.md). Called hourly by pg_cron
// through pg_net (job `carmacars-owner-debit`, scheduled by the deploy: scripts/deploy/supabase.sh debit) with
// `Authorization: Bearer <DEBIT_JOB_TOKEN>`; any other caller gets 403. The run itself is in run.ts: claim the debits
// due (app.owner_debit_claim decides the day, the hour, pauses, mandates and the notice amount), send one off-session
// PaymentIntent per invoice and attempt to Stripe, record each answer, ask Stripe again about debits processing too
// long, and close the day's run. The Stripe webhook on the site settles the rest (app.owner_debit_result).
//
// Secrets (Edge Function secrets, set by the deploy): DEBIT_JOB_TOKEN, STRIPE_SECRET_KEY. SUPABASE_DB_URL is provided.
import postgres from 'npm:postgres@3.4.5';
import { runOwnerDebits, type Sql } from './run.ts';

const TOKEN = Deno.env.get('DEBIT_JOB_TOKEN') ?? '';
const STRIPE = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false, idle_timeout: 20, onnotice: () => {} });

Deno.serve(async (req) => {
  if (!TOKEN || req.headers.get('authorization') !== `Bearer ${TOKEN}`) return new Response('Forbidden', { status: 403 });
  if (!STRIPE) return new Response('STRIPE_SECRET_KEY is not set', { status: 500 });
  try {
    const r = await runOwnerDebits(sql as unknown as Sql, STRIPE);
    return Response.json({ ok: true, ...r });
  } catch (e) {
    return Response.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 500) : 'failed' }, { status: 500 });
  }
});
