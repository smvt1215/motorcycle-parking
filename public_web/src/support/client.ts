// The support Edge Functions (supabase/functions/support-request and
// support-confirm): plain POSTs with the publishable key, like the sign-in
// check. Neither needs a sign-in; the form also sends an App Check token.

/** How the rider signs in to the App; omitted when they do not remember. */
export type AccountHint = 'google' | 'apple';

/** The form as the page collects it, already checked. */
export interface SupportSubmission {
  loginEmail: string;
  contactEmail: string;
  hint: AccountHint | null;
  message: string;
}

export type SubmitResult =
  /** Stored: the same answer whether or not an account matched. */
  | { kind: 'received'; id: string }
  /** 429 support.rate_limited. */
  | { kind: 'rateLimited' }
  /** No App Check token, or the backend refused it (401 app_check.required). */
  | { kind: 'appCheck' }
  /** No answer. */
  | { kind: 'network' }
  /** 400 request.invalid, 503, or anything else. */
  | { kind: 'unavailable' };

/** The two one-time links: the confirmation mail's and the deletion notice's 取消刪除. */
export type LinkKind = 'confirm' | 'cancel';
export type ConfirmAction = 'view' | 'confirm' | 'deny';
export type CancelAction = 'view' | 'cancel';

export type ConfirmResult =
  | 'pending'
  | 'deletion_requested'
  | 'denied'
  | 'resolved'
  | 'account_deletion_pending'
  | 'account_deleting'
  | 'unavailable';
export type CancelResult = 'pending' | 'cancelled' | 'not_pending' | 'account_deleting';

export type LinkAnswer<R> =
  | {
      kind: 'answer';
      result: R;
      /** The confirmation link only. */
      submittedAt: string | null;
      /** Masked by the backend, e.g. r***@e***.com; the confirmation link only. */
      contactEmail: string | null;
      scheduledAt: string | null;
    }
  /** 400 support.link_invalid: malformed, unknown, used, voided or expired, all alike. */
  | { kind: 'invalid' }
  | { kind: 'network' }
  | { kind: 'unavailable' };

export interface SupportPort {
  /** Null when the build has no App Check settings: the form is not offered. */
  submit: ((submission: SupportSubmission) => Promise<SubmitResult>) | null;
  confirmLink(token: string, action: ConfirmAction): Promise<LinkAnswer<ConfirmResult>>;
  cancelLink(token: string, action: CancelAction): Promise<LinkAnswer<CancelResult>>;
}

export interface SupportClientConfig {
  supabaseUrl: string;
  publishableKey: string;
  /** Null without App Check settings. */
  appCheckToken: (() => Promise<string>) | null;
  fetch: typeof fetch;
}

const confirmResults: readonly string[] = [
  'pending',
  'deletion_requested',
  'denied',
  'resolved',
  'account_deletion_pending',
  'account_deleting',
  'unavailable',
];
const cancelResults: readonly string[] = ['pending', 'cancelled', 'not_pending', 'account_deleting'];

const text = (value: unknown) => (typeof value === 'string' ? value : null);

export function createSupportClient(config: SupportClientConfig): SupportPort {
  const functions = `${config.supabaseUrl.replace(/\/$/, '')}/functions/v1`;
  const post = (name: string, body: unknown, headers: Record<string, string> = {}) =>
    config.fetch(`${functions}/${name}`, {
      method: 'POST',
      headers: { apikey: config.publishableKey, 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body),
    });

  async function submit(submission: SupportSubmission): Promise<SubmitResult> {
    let appCheck: string;
    try {
      appCheck = await config.appCheckToken!();
    } catch {
      // Offline, App Check cannot start either; otherwise reCAPTCHA refused.
      return typeof navigator !== 'undefined' && !navigator.onLine
        ? { kind: 'network' }
        : { kind: 'appCheck' };
    }
    let response: Response;
    try {
      response = await post(
        'support-request',
        {
          kind: 'account_deletion',
          login_email: submission.loginEmail,
          contact_email: submission.contactEmail,
          ...(submission.hint ? { account_hint: submission.hint } : {}),
          message: submission.message,
        },
        { 'x-firebase-appcheck': appCheck },
      );
    } catch {
      return { kind: 'network' };
    }
    const body = (await response.json().catch(() => null)) as { id?: unknown; error?: unknown } | null;
    if (response.ok && typeof body?.id === 'string') return { kind: 'received', id: body.id };
    if (response.status === 429) return { kind: 'rateLimited' };
    if (response.status === 401) return { kind: 'appCheck' };
    return { kind: 'unavailable' };
  }

  async function link<R extends string>(
    kind: LinkKind,
    token: string,
    action: string,
    known: readonly string[],
  ): Promise<LinkAnswer<R>> {
    let response: Response;
    try {
      response = await post('support-confirm', { link: kind, token, action });
    } catch {
      return { kind: 'network' };
    }
    const body = (await response.json().catch(() => null)) as Record<string, unknown> | null;
    if (response.ok && typeof body?.result === 'string' && known.includes(body.result)) {
      return {
        kind: 'answer',
        result: body.result as R,
        submittedAt: text(body.submitted_at),
        contactEmail: text(body.contact_email),
        scheduledAt: text(body.scheduled_at),
      };
    }
    if (response.status === 400 && body?.error === 'support.link_invalid') return { kind: 'invalid' };
    return { kind: 'unavailable' };
  }

  return {
    submit: config.appCheckToken ? submit : null,
    confirmLink: (token, action) => link<ConfirmResult>('confirm', token, action, confirmResults),
    cancelLink: (token, action) => link<CancelResult>('cancel', token, action, cancelResults),
  };
}
