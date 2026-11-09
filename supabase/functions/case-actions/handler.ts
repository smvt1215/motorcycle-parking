// case-actions: wakes up when a scheduled admin action is due and runs what
// is due (migration 202611090800_case_actions.sql). admin_v1 posts here
// through pg_net with the shared CASE_ACTIONS_SECRET and the action's run_at;
// this waits for that time and calls the database. pg_cron calls the same
// database function every minute for whatever this misses.
//
// Every business rule is in private.run_due_case_actions(): this only decides
// when to call it, so another executor can replace this function.
import { readBody, response } from '../_shared/http.ts';
import { sameSecret } from '../account-deletion/handler.ts';

/** The longest wait; later actions are left to pg_cron. */
export const maxWaitMs = 15_000;
/** The database clock decides what is due: arrive just after it. */
export const skewMs = 500;

export type Deps = {
  /** CASE_ACTIONS_SECRET; empty when unset. */
  secret: string;
  now(): number;
  sleep(ms: number): Promise<void>;
  /** Runs what is due; its counts are the response. */
  run(): Promise<unknown>;
};

/** How long to wait for run_at: never negative, at most maxWaitMs. */
export const waitMs = (runAt: number | null, now: number) =>
  runAt === null ? 0 : Math.min(Math.max(runAt + skewMs - now, 0), maxWaitMs);

async function readRunAt(req: Request): Promise<number | null> {
  const { run_at: runAt } = await readBody(req);
  if (runAt === undefined || runAt === null) return null;
  const time = typeof runAt === 'string' ? Date.parse(runAt) : NaN;
  if (Number.isNaN(time)) throw new Error('invalid run_at');
  return time;
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return response({ error: 'request.invalid' }, 405);
  if (
    !deps.secret ||
    !sameSecret(req.headers.get('x-case-actions-secret') ?? '', deps.secret)
  ) {
    return response({ error: 'auth.forbidden' }, 403);
  }
  let runAt: number | null;
  try {
    runAt = await readRunAt(req);
  } catch {
    return response({ error: 'request.invalid' }, 400);
  }
  const wait = waitMs(runAt, deps.now());
  if (wait > 0) await deps.sleep(wait);
  try {
    return response(await deps.run());
  } catch {
    // Whatever is due stays queued for pg_cron.
    console.error('case-actions: run failed');
    return response({ error: 'server.unavailable' }, 503);
  }
}
