// account-deletion: deletes the accounts whose 7-day cooling-off period has
// passed (#215; migration 202611011800_account_deletion.sql). pg_cron calls
// it once a day with the shared ACCOUNT_DELETION_SECRET; nobody else can.
//
// For each due request: count what is kept anonymous (for the audit), remove
// the avatar files through the Storage API (SQL cannot delete Storage
// objects), then delete the auth user. The foreign keys do the rest in the
// database: contributions keep their content without the account, personal
// rows cascade. A failed step releases the request for the next day's run.
import { response } from '../_shared/http.ts';

export const avatarBucket = 'motopark-avatars';
/** Requests handled per run; the rest wait for the next day. */
export const batchSize = 20;
/** Storage list and remove calls per account, at most this many files each. */
const avatarPage = 100, avatarRounds = 10;

export type Claimed = { request_id: string; user_id: string; source: string };

export type Deps = {
  /** ACCOUNT_DELETION_SECRET; empty when unset. */
  secret: string;
  claim(limit: number): Promise<Claimed[]>;
  /** Counts before deletion; null when the request is gone (cancelled). */
  prepare(request: string): Promise<Record<string, number> | null>;
  /** Object names directly under `<user>/` in the avatar bucket. */
  listAvatars(user: string, limit: number): Promise<string[]>;
  removeAvatars(paths: string[]): Promise<void>;
  deleteUser(user: string): Promise<void>;
  finish(
    request: string,
    source: string,
    counts: Record<string, number>,
  ): Promise<void>;
  fail(request: string, error: string): Promise<void>;
};

/** Compares in time independent of where the strings differ. */
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

class StepError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

async function step<T>(code: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch {
    throw new StepError(code);
  }
}

/** Removes every avatar of the account; returns how many files went. */
export async function removeAvatars(
  deps: Pick<Deps, 'listAvatars' | 'removeAvatars'>,
  user: string,
): Promise<number> {
  let removed = 0;
  for (let round = 0; round < avatarRounds; round++) {
    const names = await deps.listAvatars(user, avatarPage);
    if (names.length === 0) return removed;
    await deps.removeAvatars(names.map((name) => `${user}/${name}`));
    removed += names.length;
  }
  if ((await deps.listAvatars(user, 1)).length > 0) {
    throw new Error('avatars left');
  }
  return removed;
}

export type Outcome = 'executed' | 'skipped' | 'failed';

export async function deleteOne(deps: Deps, item: Claimed): Promise<Outcome> {
  try {
    const counts = await step(
      'prepare_failed',
      () => deps.prepare(item.request_id),
    );
    if (!counts) return 'skipped';
    const avatars = await step(
      'storage_failed',
      () => removeAvatars(deps, item.user_id),
    );
    await step('auth_delete_failed', () => deps.deleteUser(item.user_id));
    // The account is gone. A failed audit write cannot be retried through
    // the request (it went with the account), so it is only reported.
    try {
      await deps.finish(item.request_id, item.source, { ...counts, avatars });
    } catch {
      console.error(`account-deletion: audit failed for ${item.request_id}`);
    }
    return 'executed';
  } catch (error) {
    const code = error instanceof StepError ? error.code : 'unknown';
    try {
      await deps.fail(item.request_id, code);
    } catch {
      console.error(`account-deletion: could not record ${code}`);
    }
    return 'failed';
  }
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== 'POST') return response({ error: 'method' }, 405);
  if (
    !deps.secret ||
    !sameSecret(req.headers.get('x-deletion-secret') ?? '', deps.secret)
  ) {
    return response({ error: 'forbidden' }, 403);
  }
  let claimed: Claimed[];
  try {
    claimed = await deps.claim(batchSize);
  } catch {
    return response({ error: 'claim failed' }, 500);
  }
  const result = { executed: 0, skipped: 0, failed: 0 };
  // One at a time: a day's few requests need no parallelism, and the Auth
  // and Storage APIs are not hammered.
  for (const item of claimed) result[await deleteOne(deps, item)]++;
  return response(result, result.failed ? 500 : 200);
}
