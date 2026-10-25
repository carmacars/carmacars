// Messages that reach the workflow's annotations (the run's logs are not always readable from outside the runner):
// report(level, title, message) prints a GitHub annotation in Actions and plain text elsewhere; an uncaught error or
// rejection becomes an error annotation.
export function report(level, title, msg) {
  const m = String(msg).replace(/\r?\n/g, ' ').slice(0, 1800);
  console.log(process.env.GITHUB_ACTIONS ? `::${level} title=${title}::${m}` : `${level}: ${title}: ${m}`);
}
for (const ev of ['uncaughtException', 'unhandledRejection']) {
  process.on(ev, (e) => { report('error', 'investor video', (e && e.stack) || e); process.exit(1); });
}
