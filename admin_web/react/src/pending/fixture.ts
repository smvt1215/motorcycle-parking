import type { TimedCase, TimedCaseCounts, TimedCaseCursor } from '../api/v1/admin_v1.generated';
import type { PostgrestConnection } from '../api/v1/base';
import { SIGNED_OUT, type AdminAccess, type AdminAuthGateway, type AdminFactor } from '../auth/gateway';
import { FIXTURE_MARKER } from '../review/fixtureSource';

/*
 * Sample cases for `--mode fixture` only (main.tsx imports this behind that
 * condition). Answers at the fetch level, so the real base query and the
 * generated types are exercised. `?scenario=` and `?auth=` pick the states
 * the smoke screenshots:
 *   scenario: empty | waiting-empty | list-failed | counts-failed | second-factor | many
 *   auth: signedOut | denied | mfa | enroll | unavailable
 */

const DAY = 86_400_000;

/** 00:00 Taiwan time of the day after today: when today's deadline ends. */
function endOfToday(): number {
  const taipei = Date.now() + 8 * 3_600_000;
  return Math.floor(taipei / DAY + 1) * DAY - 8 * 3_600_000;
}

function sample(
  id: string,
  type: TimedCase['type'],
  kind: string,
  state: TimedCase['state'],
  days: number,
  extra: Partial<TimedCase> = {},
): TimedCase {
  const dueAt = endOfToday() + days * DAY;
  const bucket: TimedCase['bucket'] =
    state === 'awaiting_user' || state === 'system'
      ? 'waiting'
      : days < 0
        ? 'overdue'
        : days === 0
          ? 'today'
          : 'later';
  return {
    id,
    type,
    kind,
    state,
    due_at: new Date(dueAt).toISOString(),
    bucket,
    rank: bucket === 'waiting' ? 3 : bucket === 'overdue' ? 1 : 2,
    version: new Date(dueAt - 5 * DAY).toISOString(),
    last_activity_at: new Date(dueAt - 5 * DAY).toISOString(),
    suspicious: false,
    report_count: type === 'report' ? 1 : null,
    hidden_parts: type === 'report' ? [] : null,
    spot_id: type === 'report' ? 'fixture-spot' : null,
    pending_action: null,
    ...extra,
  };
}

/** The same six plus three as the TimedCase and TimedPhoneList boards. */
const BOARD: TimedCase[] = [
  sample('61a2d7e0-0000-4000-8000-000000000001', 'support', 'privacy', 'awaiting_admin', -1),
  sample('630f13c7-0000-4000-8000-000000000002', 'support', 'data_issue', 'awaiting_admin', 0),
  sample('8f21c04a-0000-4000-8000-000000000003', 'report', 'spot_name', 'held', 0, {
    report_count: 3,
    hidden_parts: ['spot_name'],
  }),
  sample('5d19a0b3-0000-4000-8000-000000000004', 'support', 'general', 'awaiting_admin', 1),
  sample('2c77b1e9-0000-4000-8000-000000000005', 'report', 'text', 'held', 2, { hidden_parts: ['text'] }),
  sample('4b08f6c2-0000-4000-8000-000000000006', 'support', 'complaint', 'awaiting_admin', 3, {
    suspicious: true,
  }),
  sample('71c0aa10-0000-4000-8000-000000000007', 'support', 'data_issue', 'awaiting_user', 4),
  sample('72d1bb21-0000-4000-8000-000000000008', 'support', 'privacy', 'system', 5),
  sample('73e2cc32-0000-4000-8000-000000000009', 'support', 'account_deletion', 'system', 6),
];

function manyCases(): TimedCase[] {
  const failed = sample('7a000000-0000-4000-8000-000000000000', 'support', 'data_issue', 'send_failed', 0, {
    rank: 0,
  });
  const scheduled = sample('7b000000-0000-4000-8000-000000000000', 'report', 'other', 'scheduled', 0, {
    pending_action: {
      id: '7c000000-0000-4000-8000-000000000000',
      action: 'report_keep',
      run_at: new Date(Date.now() + 10_000).toISOString(),
      irreversible: true,
      status: 'scheduled',
    },
  });
  const open = sample('7d000000-0000-4000-8000-000000000000', 'report', 'other', 'open', 1);
  const deleted = sample('7e000000-0000-4000-8000-000000000000', 'report', 'rider_name', 'spot_deleted', 1, {
    version: null,
    spot_id: null,
  });
  const fill = Array.from({ length: 116 }, (_, index) =>
    sample(
      `${String(index).padStart(8, '0')}-1111-4000-8000-000000000000`,
      'support',
      'general',
      'awaiting_admin',
      2 + (index % 9),
    ),
  );
  return [failed, scheduled, open, deleted, ...fill];
}

const scenario = () => new URLSearchParams(window.location.search).get('scenario');

function casesNow(): TimedCase[] {
  switch (scenario()) {
    case 'empty':
      return BOARD.filter((item) => item.bucket === 'waiting');
    case 'waiting-empty':
      return [];
    case 'many':
      return manyCases();
    default:
      return BOARD;
  }
}

const order = (a: TimedCase, b: TimedCase) =>
  a.rank - b.rank || a.due_at.localeCompare(b.due_at) || a.id.localeCompare(b.id);

function countsOf(items: readonly TimedCase[]): TimedCaseCounts {
  const open = items.filter((item) => item.bucket !== 'waiting');
  const byKind: Record<string, number> = {};
  for (const item of open) {
    byKind[item.type] = (byKind[item.type] ?? 0) + 1;
    byKind[`${item.type}:${item.kind}`] = (byKind[`${item.type}:${item.kind}`] ?? 0) + 1;
  }
  const count = (bucket: TimedCase['bucket']) => items.filter((item) => item.bucket === bucket).length;
  return {
    all: open.length,
    overdue: count('overdue'),
    today: count('today'),
    later: count('later'),
    waiting: count('waiting'),
    send_failed: items.filter((item) => item.state === 'send_failed').length,
    by_kind: byKind,
    as_of: new Date().toISOString(),
  };
}

const answer = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'x-sample-data': FIXTURE_MARKER },
  });

const SECOND_FACTOR = { code: 'PT403', message: 'auth.aal2_required', details: null };
const BROKEN = { code: 'XX000', message: 'internal', details: null };

function timedCases(body: {
  p_kind?: string;
  p_bucket?: string;
  p_cursor?: TimedCaseCursor | null;
  p_limit?: number;
}) {
  const {
    p_kind: kind = 'all',
    p_bucket: bucket = 'all',
    p_cursor: cursor = null,
    p_limit: limit = 50,
  } = body;
  const matches = casesNow()
    .filter((item) => kind === 'all' || kind === item.type || kind === `${item.type}:${item.kind}`)
    .filter((item) => (bucket === 'all' ? item.bucket !== 'waiting' : item.bucket === bucket))
    .sort(order)
    .filter(
      (item) =>
        !cursor || order(item, { ...item, rank: cursor.rank, due_at: cursor.due_at, id: cursor.id }) > 0,
    );
  const items = matches.slice(0, limit);
  const last = items.at(-1);
  return {
    items,
    next_cursor:
      matches.length > limit && last ? { rank: last.rank, due_at: last.due_at, id: last.id } : null,
  };
}

/** A pretend PostgREST for admin_v1's two read functions. */
export function fixturePostgrest(): PostgrestConnection {
  return {
    url: 'https://fixture.invalid',
    anonKey: 'fixture',
    accessToken: () => 'fixture',
    fetch: async (input, init) => {
      await new Promise((resolve) => setTimeout(resolve, 300));
      const url = String(input);
      const current = scenario();
      if (current === 'second-factor') return answer(SECOND_FACTOR, 403);
      if (url.endsWith('/rpc/timed_case_counts')) {
        if (current === 'list-failed' || current === 'counts-failed') return answer(BROKEN, 500);
        return answer(countsOf(casesNow()));
      }
      if (url.endsWith('/rpc/timed_cases')) {
        if (current === 'list-failed') return answer(BROKEN, 500);
        return answer(timedCases(JSON.parse(String(init?.body ?? '{}'))));
      }
      return answer({ code: 'PT404', message: 'not_found', details: null }, 404);
    },
  };
}

const ACCESS: Record<string, AdminAccess> = {
  signedOut: SIGNED_OUT,
  denied: { signedIn: true, userId: 'u', email: 'rider@example.com', isAdmin: false, aal2: false },
  mfa: { signedIn: true, userId: 'u', email: 'admin@example.com', isAdmin: true, aal2: false },
  enroll: { signedIn: true, userId: 'u', email: 'admin@example.com', isAdmin: true, aal2: false },
};
const READY: AdminAccess = {
  signedIn: true,
  userId: 'u',
  email: 'admin@example.com',
  isAdmin: true,
  aal2: true,
};

/** Signed in as an admin unless `?auth=` asks for another state. */
export function fixtureGateway(search: string): AdminAuthGateway {
  const mode = new URLSearchParams(search).get('auth') ?? 'ready';
  let access = ACCESS[mode] ?? READY;
  const factors: AdminFactor[] =
    mode === 'enroll' ? [] : [{ id: 'f1', name: '手機驗證器', type: 'totp', verified: true }];
  let listener = () => undefined as void;
  const change = (next: AdminAccess) => {
    access = next;
    listener();
  };
  return {
    access: async () => {
      if (mode === 'unavailable') throw new Error('offline');
      return access;
    },
    onChange: (next) => {
      listener = next;
      return () => undefined;
    },
    accessToken: async () => 'fixture',
    takeSignInError: () => false,
    signIn: async () => change(READY),
    signOut: async () => change(SIGNED_OUT),
    listFactors: async () => factors,
    enroll: async (type) => ({
      id: 'new',
      type,
      qrCode: 'data:image/svg+xml;utf-8,<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"/>',
      secret: 'FIXTURESECRET',
    }),
    challenge: async () => ({ id: 'c', expiresAt: Date.now() + 60_000 }),
    verify: async () => change(READY),
    unenroll: async () => undefined,
  };
}
