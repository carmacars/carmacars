import './self-heal.css';
import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card, t } from '@/features/admin/ui';
import { SOURCE_WORDS, STATUS_WORDS, attemptWords, healedWords, saveOptions, splitIncidents, successRate, type HealIncident, type HealStatus } from './model';

// Admin > Self-healing (release 50, migration 4800): what the site fixed by itself, what it is fixing, what needs a person and
// the fix library. A healed incident is a quiet line here; only an escalation alerts. `readOnly` (the connector-like view for
// a portal that may only read) leaves out every button.
export function SelfHealView({ s, readOnly = false }: { s: HealStatus; readOnly?: boolean }) {
  const { escalated, working, healed } = splitIncidents(s.incidents);
  return (
    <div className="sh2" data-testid="self-heal">
      <p className="small muted sh2__note" data-testid="self-heal-note">{s.note}</p>
      <ul className="sh2__tiles" aria-label="Self-healing this week">
        <li className={escalated.length ? 'is-warn' : undefined}><b className="num">{s.counts.escalated}</b><span>need you</span></li>
        <li><b className="num">{s.counts.open}</b><span>being fixed</span></li>
        <li className="is-ok"><b className="num">{s.counts.healed_by_playbook_7d}</b><span>fixed by itself this week</span></li>
        <li><b className="num">{s.counts.attempts_7d}</b><span>fixes tried this week</span></li>
      </ul>
      {!s.enabled && <p className="alert alert--warn" role="status"><span>Self-healing is switched off: problems are still listed, nothing is fixed.</span></p>}

      <Card title={`Needs you (${escalated.length})`} id="escalated" testId="self-heal-escalated" tone={escalated.length ? 'warn' : undefined}>
        {escalated.length ? <ol className="sh2__list">{escalated.map((i) => <Incident key={i.id} i={i} s={s} readOnly={readOnly} />)}</ol>
          : <p className="small" data-testid="self-heal-none-escalated">Nothing waiting for a person.</p>}
      </Card>

      <Card title={`Being fixed (${working.length})`} id="working" testId="self-heal-working">
        {working.length ? <ol className="sh2__list">{working.map((i) => <Incident key={i.id} i={i} s={s} readOnly={readOnly} />)}</ol>
          : <p className="small">No problem open now.</p>}
      </Card>

      <Card title={`Fixed in the last 7 days (${healed.length})`} id="healed" testId="self-heal-healed">
        {healed.length ? (
          <ul className="sh2__log small">{healed.map((i) => (
            <li key={i.id} id={`incident-${i.number}`} data-testid={`self-heal-healed-${i.number}`}>
              <span className="sh2__when">{i.healed_at ? t(i.healed_at) : ''}</span>
              <span><b>#{i.number}</b> {i.title}: {healedWords(i)}{i.tried.length ? ` (${i.tried.filter((a) => a.verified).map((a) => a.playbook ?? a.action).join(', ') || `${i.tried.length} tried`})` : ''}{i.resolution_note ? `. ${i.resolution_note}` : ''}</span>
              {!readOnly && i.healed_by === 'staff' && !i.saved_playbook_id && !i.money && <SaveFix i={i} s={s} />}
            </li>))}</ul>
        ) : <p className="small">Nothing to show yet.</p>}
      </Card>

      <Card title={`Fix library (${s.playbooks.length})`} id="playbooks" testId="self-heal-playbooks"
        aside={<span className="small muted">The best success rate runs first</span>}>
        <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Fix library">
          <table className="ad-table ad-table--dense sh2__table">
            <thead><tr><th scope="col">Fix</th><th scope="col">When</th><th scope="col">Does</th><th scope="col" className="num">Fixed</th><th scope="col" className="num">Failed</th><th scope="col">On</th></tr></thead>
            <tbody>{s.playbooks.map((p) => {
              const rate = successRate(p);
              return (
                <tr key={p.id} data-testid={`playbook-${p.key}`} data-enabled={p.enabled}>
                  <td><b>{p.title}</b>{p.learned_from && <span className="ad-sub">{p.learned_from}</span>}{p.disabled_reason && <span className="ad-sub ad-late">{p.disabled_reason}</span>}</td>
                  <td><span className="ad-pill">{SOURCE_WORDS[p.source]}</span>{(p.match_key || p.match_pattern || p.match_state) && <span className="ad-sub sh2__sig">{[p.match_key, p.match_pattern, p.match_state].filter(Boolean).join(' · ')}</span>}</td>
                  <td>{p.action_label}{p.action_kind === 'server' && <span className="ad-sub">on the server</span>}</td>
                  <td className="num">{p.successes}{rate !== null && <span className="ad-sub">{rate}%</span>}</td>
                  <td className="num">{p.failures}</td>
                  <td className="sh2__toggle">{readOnly ? (p.enabled ? 'On' : 'Off') : (
                    <Act ops action="heal_playbook_toggle" payload={{ id: p.id, enabled: !p.enabled }} label={p.enabled ? 'Switch off' : 'Switch on'}
                      variant={p.enabled ? 'quiet' : 'ghost'} done={p.enabled ? 'Switched off.' : 'Switched on.'} refresh={['/admin/self-healing']} testId={`playbook-toggle-${p.key}`} />)}</td>
                </tr>);
            })}</tbody>
          </table>
        </div>
      </Card>

      {s.server && <Card title="The server" id="server" testId="self-heal-server">
        {s.server.reported_at ? (
          <p className="small">Last report {t(s.server.reported_at)}: build {s.server.web_tag ?? 'unknown'}{s.server.deployed_at ? `, deployed ${t(s.server.deployed_at)}` : ''}
            {s.server.previous_tag ? ` (the one before, ${s.server.previous_tag}, is kept for a rollback)` : ''}; website {s.server.web_health ?? 'unknown'}
            {s.server.disk_pct !== null ? `, disk ${s.server.disk_pct}% full` : ''}{s.server.cert_days !== null ? `, certificate ${s.server.cert_days} days left` : ''}.</p>
        ) : <p className="small">The heal agent on the server has not reported yet: it is installed by the next server deploy.</p>}
        {s.requests.length > 0 && <ul className="small muted sh2__log">{s.requests.slice(0, 8).map((r) => (
          <li key={r.id}><span className="sh2__when">{t(r.created_at)}</span><span>{s.actions.find((a) => a.key === r.action)?.label ?? r.action}: {r.status === 'done' ? 'done' : r.status === 'pending' || r.status === 'claimed' ? 'waiting' : 'failed'}{r.result ? ` (${r.result})` : ''}</span></li>))}</ul>}
      </Card>}
    </div>
  );
}

function Incident({ i, s, readOnly }: { i: HealIncident; s: HealStatus; readOnly: boolean }) {
  return (
    <li className={`sh2__inc is-${i.status}`} id={`incident-${i.number}`} data-testid={`self-heal-incident-${i.number}`} data-status={i.status}>
      <div className="sh2__head">
        <span className={`ad-pill${i.status === 'escalated' ? ' ad-pill--red' : ''}`}>{STATUS_WORDS[i.status]}</span>
        <b className="sh2__title">#{i.number} {i.title}</b>
        <span className="ad-sub">{SOURCE_WORDS[i.source]} · first seen {t(i.first_seen)} · seen {i.seen_count} times{i.money ? ' · money: never fixed automatically' : ''}</span>
      </div>
      {i.detail && <p className="small sh2__detail">{i.detail}</p>}
      {i.escalation_reason && <p className="small"><b>Why it needs you:</b> {i.escalation_reason}</p>}
      {i.tried.length > 0 && <ol className="small sh2__tried">{i.tried.map((a, n) => <li key={n}><span className="sh2__when">{t(a.at)}</span><span>{attemptWords(a)}</span></li>)}</ol>}
      {(i.bug_report_id || i.path) && <p className="small">{i.bug_report_id && <Link prefetch={false} className="link" href={`/admin/bug-reports/${i.bug_report_id}`}>The bug report with the evidence</Link>}
        {i.bug_report_id && i.path ? ' · ' : ''}{i.path?.startsWith('/') && <span className="muted">{i.path}</span>}</p>}
      {!readOnly && i.status === 'escalated' && (
        <div className="sh2__acts">
          <Act ops action="heal_resolve" payload={{ incident: i.id }} label="Resolve" variant="ghost" done="Resolved." refresh={['/admin/self-healing']} testId={`self-heal-resolve-${i.number}`}
            fields={[{ name: 'note', label: 'What fixed it', type: 'textarea', required: true, hint: 'One line for the next person.' }]} />
          {!i.money && <SaveFix i={i} s={s} />}
        </div>)}
    </li>
  );
}

function SaveFix({ i, s }: { i: HealIncident; s: HealStatus }) {
  return (
    <Act ops action="heal_save_fix" payload={{ incident: i.id }} label="Save as fix" variant="primary" done="Saved in the fix library." refresh={['/admin/self-healing']}
      testId={`self-heal-save-${i.number}`} submitLabel="Save the fix"
      confirm={`Next time "${i.title}" happens, the site runs this by itself before it asks anyone. Only the listed actions can be saved: each is safe to repeat and never touches money.`}
      fields={[
        { name: 'action', label: 'What fixed it', type: 'select', required: true, options: saveOptions(s.actions, s.playbooks, i.source) },
        { name: 'title', label: 'Name of the fix', placeholder: 'For example: Restart the website when the sign-in page fails' },
        { name: 'match_pattern', label: 'Only when the message contains (optional)', placeholder: 'For example: socket has been closed' },
        { name: 'note', label: 'Note for the incident', type: 'textarea' }
      ]} />
  );
}
