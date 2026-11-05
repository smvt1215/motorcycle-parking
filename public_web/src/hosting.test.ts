import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { APPLE_SCRIPT, GSI_SCRIPT } from './auth/providers';

// The public site's Hosting settings (firebase.json, target public-staging):
// the CSP must let the page load what the code loads. Tests run from public_web/.
const firebase = JSON.parse(readFileSync(resolve(process.cwd(), '../firebase.json'), 'utf8')) as {
  hosting: {
    target: string;
    public: string;
    headers: { source: string; headers: { key: string; value: string }[] }[];
  }[];
};
const site = firebase.hosting.find((entry) => entry.target === 'public-staging')!;
const all = site.headers.find((rule) => rule.source === '**')!.headers;
const header = (key: string) => all.find((h) => h.key === key)?.value;
const csp = new Map(
  header('Content-Security-Policy')!
    .split(';')
    .map((part) => part.trim().split(/\s+/))
    .map(([name, ...sources]) => [name!, sources] as const),
);

/** Whether a CSP source list allows the URL: an origin, or a path prefix ending in /, or the exact URL. */
function allows(directive: string, url: string): boolean {
  const target = new URL(url);
  return (csp.get(directive) ?? []).some((source) => {
    if (!source.startsWith('https://')) return false;
    const allowed = new URL(source.replace('://*.', '://wildcard.'));
    const host = source.includes('://*.')
      ? target.host.endsWith(allowed.host.replace(/^wildcard/, ''))
      : target.host === allowed.host;
    if (!host) return false;
    if (allowed.pathname === '/' && !source.endsWith('/') && source.split('/').length <= 3) return true;
    return allowed.pathname.endsWith('/')
      ? target.pathname.startsWith(allowed.pathname)
      : target.pathname === allowed.pathname;
  });
}

describe('public Hosting (firebase.json public-staging)', () => {
  it('serves the built site and sends every path to the app', () => {
    expect(site.public).toBe('public_web/dist');
  });

  it("allows the sign-in providers' scripts the page loads", () => {
    expect(allows('script-src', GSI_SCRIPT)).toBe(true);
    expect(allows('script-src', APPLE_SCRIPT)).toBe(true);
    // App Check's reCAPTCHA Enterprise provider loads its script and frame from Google.
    expect(allows('script-src', 'https://www.google.com/recaptcha/enterprise.js?render=site-key')).toBe(true);
    expect(allows('frame-src', 'https://www.google.com/recaptcha/enterprise/anchor')).toBe(true);
    expect(allows('frame-src', 'https://accounts.google.com/gsi/button')).toBe(true);
  });

  it('lets the page reach Supabase, App Check and Google sign-in', () => {
    expect(allows('connect-src', 'https://abcdefgh.supabase.co/functions/v1/deletion-precheck')).toBe(true);
    expect(
      allows(
        'connect-src',
        'https://content-firebaseappcheck.googleapis.com/v1/projects/p/apps/a:exchangeRecaptchaEnterpriseToken',
      ),
    ).toBe(true);
    expect(
      allows('connect-src', 'https://firebaseinstallations.googleapis.com/v1/projects/p/installations'),
    ).toBe(true);
    expect(allows('connect-src', 'https://accounts.google.com/gsi/status')).toBe(true);
  });

  it('allows nothing else to run or frame it', () => {
    expect(allows('script-src', 'https://example.com/x.js')).toBe(false);
    expect(csp.get('frame-ancestors')).toEqual(["'none'"]);
    expect(csp.get('object-src')).toEqual(["'none'"]);
    expect(header('X-Frame-Options')).toBe('DENY');
  });

  it('keeps the sign-in popups able to answer, and stays indexable', () => {
    expect(header('Cross-Origin-Opener-Policy')).toBe('same-origin-allow-popups');
    expect(header('X-Robots-Tag')).toBeUndefined();
  });
});
