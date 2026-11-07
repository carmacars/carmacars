// local only (not committed): the machine's newer headless shell
import base from './playwright.config';
export default { ...base, use: { ...base.use, launchOptions: { ...(base.use?.launchOptions ?? {}), executablePath: '/opt/pw-browsers/chromium_headless_shell-1243/chrome-headless-shell-linux64/chrome-headless-shell' } }, webServer: undefined };
