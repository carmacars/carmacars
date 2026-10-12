import Link from 'next/link';
import { Suspense } from 'react';
import { PageHead } from '@/components/Blocks';
import { JsonLd } from '@/components/JsonLd';
import { SlotPicture } from '@/components/Picture';
import { waLink } from '@/components/Footer';
import { ContactForm } from '@/features/forms/ContactForm';
import { businessLd } from '@/features/seo/business';
import { breadcrumbLd, pageMeta, type Trail } from '@/features/seo/meta';
import { fill, getFacts, getSettings, getTokens, siteUrl, slotPhoto } from '@/lib/site';

export const revalidate = 3600;
const trail: Trail = [['Home', '/'], ['Contact']];

export async function generateMetadata() {
  const t = await getTokens();
  return pageMeta({ title: fill('Contact {{brand}} | Car rental in {{city}}', t), path: '/contact',
    description: fill('Contact {{brand}} about renting a car in {{city}}, a booking you have made, or listing your own car. {{hours}}. Call, WhatsApp or send a message and a person replies.', t) });
}

const Mail = ({ a }: { a?: string | null }) => (a ? <a className="link" href={`mailto:${a}`}>{a}</a> : null);

export default async function Contact() {
  const [s, f, t, photo] = await Promise.all([getSettings(), getFacts(), getTokens(), slotPhoto('contact.city')]);
  const E = f.email_aliases;
  const tel = (e164: string | null, d: string | null) => (e164 ? <a className="link" href={`tel:${e164}`}>{d}</a> : null);
  return (
    <div className="p-contact">
      <JsonLd graph={[breadcrumbLd(trail, '/contact'), businessLd(s, siteUrl())]} />
      <PageHead trail={trail} h1="Talk to a person." lead={`Questions about a car, a booking or listing your own. ${t.reply}.`} />
      <section className="section">
        <div className="wrap grid">
          <div className="c-5 stack-lg">
            <table className="spec"><tbody>
              {s.phone && <tr><th scope="row">Phone</th><td>{tel(s.phone, s.phone_display)}</td></tr>}
              {s.whatsapp && <tr><th scope="row">WhatsApp</th><td><a className="link" href={waLink(s.whatsapp)} rel="noopener">WhatsApp {s.whatsapp_display}</a></td></tr>}
              <tr><th scope="row">Email</th><td><Mail a={E.contact ?? s.public_email} /></td></tr>
              {s.roadside_phone && <tr><th scope="row">On a rental right now</th><td>Call the 24-hour incident and roadside line, {tel(s.roadside_phone, s.roadside_phone_display)}</td></tr>}
              <tr><th scope="row">Hours</th><td>{s.opening_hours_text}. {t.reply}.</td></tr>
              {s.street_address && <tr><th scope="row">Location</th><td>{s.street_address}</td></tr>}
              <tr><th scope="row">Where we rent</th><td>{fill('{{serviceArea}}. Delivery anywhere, including {{airports}}', t)}</td></tr>
            </tbody></table>
            <table className="spec"><caption className="small strong">Write to the right desk</caption><tbody>
              {E.bookings && <tr><th scope="row">A booking or a request</th><td><Mail a={E.bookings} /></td></tr>}
              {E.owners && <tr><th scope="row">Listing your car</th><td><Mail a={E.owners} /></td></tr>}
              {E.billing && <tr><th scope="row">A charge or a statement</th><td><Mail a={E.billing} /></td></tr>}
              {E.privacy && <tr><th scope="row">Your personal information</th><td><Mail a={E.privacy} /></td></tr>}
            </tbody></table>
            <div className="alert alert--error"><span className="alert__title">After an accident</span><span>If anyone is hurt, call 911 first. Then call our 24-hour line{s.roadside_phone ? <>, {tel(s.roadside_phone, s.roadside_phone_display)},</> : ''} as soon as it is safe, and within {t.callHours} hours.</span></div>
            <p className="small">Most questions are answered in the <Link className="link" href="/faq">FAQ</Link>.</p>
          </div>
          <div className="c-6 s-7">
            <Suspense fallback={null}><ContactForm reply={t.reply!} /></Suspense>
          </div>
        </div>
      </section>
      <section className="band band--short on-dark" aria-hidden="true"><div className="band__media photo fx-drift"><SlotPicture p={photo} alt="" /></div></section>
    </div>
  );
}
