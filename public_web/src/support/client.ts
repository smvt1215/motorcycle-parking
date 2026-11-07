// The support Edge Functions (supabase/functions/support-request,
// support-confirm and support-case): plain POSTs with the publishable key, like
// the sign-in check. None needs a sign-in; the form also sends an App Check
// token. All five kinds of #295 go through the form; the login email's owner
// confirms account_deletion and privacy through the one-time link.

/** How the rider signs in to the App; omitted when they do not remember. */
export type AccountHint = 'google' | 'apple';
export type PrivacyRight = 'access' | 'correction' | 'copy';
/** The kinds with only a contact email: their receipt carries the case link. */
export type CaseKind = 'general' | 'data_issue' | 'complaint';
export type SupportKind = CaseKind | 'privacy' | 'account_deletion';

/** The form as the page collects it, already checked. */
export type SupportSubmission =
  | { kind: CaseKind; contactEmail: string; subject: string; message: string }
  | {
      kind: 'privacy';
      loginEmail: string;
      contactEmail: string;
      right: PrivacyRight;
      subject: string;
      message: string;
    }
  | {
      kind: 'account_deletion';
      loginEmail: string;
      contactEmail: string;
      hint: AccountHint | null;
      message: string;
    };

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
export type ConfirmAction = 'view' | 'confirm' | 'deny';
export type CancelAction = 'view' | 'cancel';

export type DeletionResult =
  | 'pending'
  | 'deletion_requested'
  | 'denied'
  | 'resolved'
  | 'account_deletion_pending'
  | 'account_deleting'
  | 'unavailable';
/** A privacy request's: account_deleting means its account is gone (support_request_link). */
export type PrivacyResult = 'pending' | 'verified' | 'denied' | 'resolved' | 'account_deleting';
export type CancelResult = 'pending' | 'cancelled' | 'not_pending' | 'account_deleting';

/** What the owner of the login email is confirming. */
export interface PrivacyDetails {
  right: PrivacyRight | null;
  subject: string | null;
  message: string | null;
}

type Answer<R, Extra = unknown> = {
  kind: 'answer';
  result: R;
  /** The confirmation link only. */
  submittedAt: string | null;
  /** Masked by the backend, e.g. r***@e***.com; the confirmation link only. */
  contactEmail: string | null;
  scheduledAt: string | null;
} & Extra;

type LinkFailure =
  /** 400 support.link_invalid: malformed, unknown, used, voided or expired, all alike. */
  { kind: 'invalid' } | { kind: 'network' } | { kind: 'unavailable' };

/** What every link call ends in, whatever its answer carries. */
export type LinkOutcome = { kind: 'answer' } | LinkFailure;
export type LinkAnswer<R> = Answer<R> | LinkFailure;
/** The confirmation link says which kind it is for: `privacy` is null for a deletion. */
export type ConfirmAnswer =
  | Answer<DeletionResult, { privacy: null }>
  | Answer<PrivacyResult, { privacy: PrivacyDetails }>
  | LinkFailure;

/** One entry of a case's thread: `in` is the rider's, `out` the administrators'. */
export interface CaseMessage {
  direction: 'in' | 'out';
  body: string;
  createdAt: string | null;
}

export interface CaseView {
  kind: string;
  status: string;
  submittedAt: string | null;
  canReply: boolean;
  messages: CaseMessage[];
}

export type CaseAnswer = { kind: 'answer'; view: CaseView } | LinkFailure;
export type CaseReplyResult =
  /** `reopened`: the case was closed and this reply opened it again. */
  | { kind: 'received'; reopened: boolean }
  /** 409 support.case_closed: closed for over 30 days. */
  | { kind: 'closed' }
  /** 429 support.rate_limited: a limit of the case or of this link. */
  | { kind: 'rateLimited' }
  | LinkFailure;

export interface SupportPort {
  /** Null when the build has no App Check settings: the form is not offered. */
  submit: ((submission: SupportSubmission) => Promise<SubmitResult>) | null;
  confirmLink(token: string, action: ConfirmAction): Promise<ConfirmAnswer>;
  cancelLink(token: string, action: CancelAction): Promise<LinkAnswer<CancelResult>>;
  /** Opening the case link: changes nothing. */
  caseView(token: string): Promise<CaseAnswer>;
  caseReply(token: string, message: string): Promise<CaseReplyResult>;
}

export interface SupportClientConfig {
  supabaseUrl: string;
  publishableKey: string;
  /** Null without App Check settings. */
  appCheckToken: (() => Promise<string>) | null;
  fetch: typeof fetch;
}

const deletionResults: readonly string[] = [
  'pending',
  'deletion_requested',
  'denied',
  'resolved',
  'account_deletion_pending',
  'account_deleting',
  'unavailable',
];
const privacyResults: readonly string[] = ['pending', 'verified', 'denied', 'resolved', 'account_deleting'];
const cancelResults: readonly string[] = ['pending', 'cancelled', 'not_pending', 'account_deleting'];
const privacyRights: readonly string[] = ['access', 'correction', 'copy'];

type Body = Record<string, unknown> | null;

const text = (value: unknown) => (typeof value === 'string' ? value : null);

/** What the form sends for each kind (support-request's parse). */
function requestBody(submission: SupportSubmission) {
  const common = {
    kind: submission.kind,
    contact_email: submission.contactEmail,
    message: submission.message,
  };
  switch (submission.kind) {
    case 'account_deletion':
      return {
        ...common,
        login_email: submission.loginEmail,
        ...(submission.hint ? { account_hint: submission.hint } : {}),
      };
    case 'privacy':
      return {
        ...common,
        login_email: submission.loginEmail,
        privacy_right: submission.right,
        subject: submission.subject,
      };
    default:
      return { ...common, subject: submission.subject };
  }
}

function caseMessage(value: unknown): CaseMessage | null {
  const m = value as { direction?: unknown; body?: unknown; created_at?: unknown } | null;
  if ((m?.direction !== 'in' && m?.direction !== 'out') || typeof m.body !== 'string') return null;
  return { direction: m.direction, body: m.body, createdAt: text(m.created_at) };
}

/** The `ok` answer; null for anything else, which the page shows as an error. */
function caseView(body: Body): CaseView | null {
  if (body?.result !== 'ok' || !Array.isArray(body.messages)) return null;
  const { kind, status, can_reply: canReply } = body;
  if (typeof kind !== 'string' || typeof status !== 'string' || typeof canReply !== 'boolean') return null;
  const messages = body.messages.map(caseMessage);
  if (messages.includes(null)) return null;
  return {
    kind,
    status,
    submittedAt: text(body.submitted_at),
    canReply,
    messages: messages as CaseMessage[],
  };
}

/** The fields a link's good answer has, whichever link it is. */
const answered = (body: Body) => ({
  kind: 'answer' as const,
  submittedAt: text(body?.submitted_at),
  contactEmail: text(body?.contact_email),
  scheduledAt: text(body?.scheduled_at),
});

const failed = (response: Response, body: Body): LinkFailure =>
  response.status === 400 && body?.error === 'support.link_invalid'
    ? { kind: 'invalid' }
    : { kind: 'unavailable' };

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
      response = await post('support-request', requestBody(submission), { 'x-firebase-appcheck': appCheck });
    } catch {
      return { kind: 'network' };
    }
    const body = (await response.json().catch(() => null)) as { id?: unknown; error?: unknown } | null;
    if (response.ok && typeof body?.id === 'string') return { kind: 'received', id: body.id };
    if (response.status === 429) return { kind: 'rateLimited' };
    if (response.status === 401) return { kind: 'appCheck' };
    return { kind: 'unavailable' };
  }

  /** One link call; null when no answer came. */
  async function call(name: string, payload: unknown) {
    let response: Response;
    try {
      response = await post(name, payload);
    } catch {
      return null;
    }
    const body = (await response.json().catch(() => null)) as Body;
    return { response, body };
  }

  async function confirmLink(token: string, action: ConfirmAction): Promise<ConfirmAnswer> {
    const sent = await call('support-confirm', { link: 'confirm', token, action });
    if (!sent) return { kind: 'network' };
    const { response, body } = sent;
    if (!response.ok) return failed(response, body);
    const result = text(body?.result) ?? '';
    // Each kind has its own wording: a result that is not the kind's, or a
    // kind this page does not know, must not land on another kind's page.
    if (body?.kind === 'account_deletion' && deletionResults.includes(result)) {
      return { ...answered(body), result: result as DeletionResult, privacy: null };
    }
    if (body?.kind === 'privacy' && privacyResults.includes(result)) {
      const right = text(body.privacy_right);
      return {
        ...answered(body),
        result: result as PrivacyResult,
        privacy: {
          right: right && privacyRights.includes(right) ? (right as PrivacyRight) : null,
          subject: text(body.subject),
          message: text(body.message),
        },
      };
    }
    return { kind: 'unavailable' };
  }

  async function cancelLink(token: string, action: CancelAction): Promise<LinkAnswer<CancelResult>> {
    const sent = await call('support-confirm', { link: 'cancel', token, action });
    if (!sent) return { kind: 'network' };
    const { response, body } = sent;
    if (!response.ok) return failed(response, body);
    const result = text(body?.result) ?? '';
    if (!cancelResults.includes(result)) return { kind: 'unavailable' };
    return { ...answered(body), result: result as CancelResult };
  }

  async function openCase(token: string): Promise<CaseAnswer> {
    const sent = await call('support-case', { token, action: 'view' });
    if (!sent) return { kind: 'network' };
    const { response, body } = sent;
    if (!response.ok) return failed(response, body);
    const view = caseView(body);
    return view ? { kind: 'answer', view } : { kind: 'unavailable' };
  }

  async function caseReply(token: string, message: string): Promise<CaseReplyResult> {
    const sent = await call('support-case', { token, action: 'reply', message });
    if (!sent) return { kind: 'network' };
    const { response, body } = sent;
    if (response.ok) {
      return body?.result === 'received'
        ? { kind: 'received', reopened: body.reopened === true }
        : { kind: 'unavailable' };
    }
    if (response.status === 409) return { kind: 'closed' };
    if (response.status === 429) return { kind: 'rateLimited' };
    return failed(response, body);
  }

  return {
    submit: config.appCheckToken ? submit : null,
    confirmLink,
    cancelLink,
    caseView: openCase,
    caseReply,
  };
}
