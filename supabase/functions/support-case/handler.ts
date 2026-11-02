// support-case: the case link in every case mail (#295). The site's case
// page (https://motoparking.smvtstudio.com/support/case) reads the token
// from the link's fragment and posts it here:
//
//   view   the case: its code, kind, state, when it came in, whether the
//          rider can still add to it, and the thread (the original text
//          first; direction, text and time only). Changes nothing.
//   reply  adds the rider's text to the same case (1–4000 characters). A
//          case closed within 30 days opens again; after that the link
//          says to fill in the form again (support.case_closed).
//
// public.support_case_link() (migration 202611020100_support_cases.sql) does
// the work: the token is `<case id>.<secret>`, only the secret's SHA-256 is
// stored, a link lasts 30 days and takes 5 replies, a case 10 a Taiwan day
// and 50 in all. Every bad token is the same 400. A reply tells ops@
// (SUPPORT_MAIL_TO) the case id and the admin page link, nothing else.
import { cors, readBody, response } from '../_shared/http.ts';
import { parseConfirmToken } from '../_shared/support_token.ts';
import type { Notifier } from '../support-request/handler.ts';
import { supportCode } from '../support-request/resend.ts';

export const actions = ['view', 'reply'] as const;
export type Action = typeof actions[number];

export type CaseResult =
  | { result: 'invalid' | 'closed' | 'rate_limited' }
  | {
    result: 'ok';
    id: string;
    kind: string;
    status: string;
    submitted_at: string;
    can_reply: boolean;
    messages: { direction: 'in' | 'out'; body: string; created_at: string }[];
  }
  | { result: 'received'; message_id: string; reopened: boolean };

export type Deps = {
  link(
    id: string,
    tokenHash: string,
    action: Action,
    body: string | null,
  ): Promise<CaseResult>;
  notifier: Notifier;
  /** The admin page of one case. */
  adminUrl(id: string): string;
};

// Control characters other than tab and newlines are dropped.
// deno-lint-ignore no-control-regex
const control = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

/**
 * 4000 characters of text, each up to 12 code units once JSON-escaped (an
 * astral character as two \u escapes), and the other fields.
 */
export const maxBodyLength = 64 * 1024;

const fail = (error: string, status: number) => response({ error }, status);

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('request.invalid', 405);

  let body: Record<string, unknown>;
  try {
    body = await readBody(req, maxBodyLength);
  } catch {
    return fail('request.invalid', 400);
  }
  const action = body.action ?? 'view';
  if (!actions.includes(action as Action)) return fail('request.invalid', 400);
  let text: string | null = null;
  if (action === 'reply') {
    text = typeof body.message === 'string'
      ? body.message.replace(control, '').trim()
      : '';
    if (text === '' || [...text].length > 4000) {
      return fail('request.invalid', 400);
    }
  }
  const token = await parseConfirmToken(body.token);
  if (!token) return fail('support.link_invalid', 400);
  let found: CaseResult;
  try {
    found = await deps.link(token.id, token.hash, action as Action, text);
  } catch {
    return fail('server.unavailable', 503);
  }
  switch (found.result) {
    case 'ok':
      return response({
        result: 'ok',
        code: supportCode(found.id),
        kind: found.kind,
        status: found.status,
        submitted_at: found.submitted_at,
        can_reply: found.can_reply,
        messages: found.messages.map((m) => ({
          direction: m.direction,
          body: m.body,
          created_at: m.created_at,
        })),
      });
    case 'received':
      try {
        await deps.notifier.notify({
          id: token.id,
          adminUrl: deps.adminUrl(token.id),
          replyId: found.message_id,
        });
      } catch {
        console.error(`support-case: notice failed for ${token.id}`);
      }
      return response({ result: 'received', reopened: found.reopened });
    case 'closed':
      return fail('support.case_closed', 409);
    case 'rate_limited':
      return fail('support.rate_limited', 429);
    default:
      return fail('support.link_invalid', 400);
  }
}
