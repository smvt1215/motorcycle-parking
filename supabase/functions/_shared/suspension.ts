import { response } from './http.ts';

/**
 * App 層級停權（#331）：停權中的帳號照常登入、管理與刪除帳號，只有 App 的
 * 寫入被擋。寫入的 Edge Function 回 403
 * `{"error":"account.suspended","until":<ISO|null>}`；until 為 null 代表
 * 無限期。
 */
export interface Suspension {
  suspended: boolean;
  /** ISO time; null when indefinite or not suspended. */
  until: string | null;
}

export const suspendedError = 'account.suspended';

export const suspendedResponse = (until: string | null) =>
  response({ error: suspendedError, until }, 403);

/** public.suspension_status() as supabase-js returns it. */
export function parseSuspension(data: unknown): Suspension {
  const value = data as Record<string, unknown> | null;
  if (!value || typeof value.suspended !== 'boolean') {
    throw new Error('invalid suspension status');
  }
  return {
    suspended: value.suspended,
    until: typeof value.until === 'string' ? value.until : null,
  };
}

/** The database refused a suspended account (PT403 account.suspended). */
export function suspendedRefusal(
  error: { code?: string; message?: string; details?: string | null } | null,
): Suspension | null {
  if (error?.code !== 'PT403' || error.message !== suspendedError) return null;
  let until: string | null = null;
  try {
    const detail = JSON.parse(error.details ?? 'null');
    if (typeof detail?.until === 'string') until = detail.until;
  } catch {
    // The refusal holds without the date.
  }
  return { suspended: true, until };
}

/**
 * Reads `admin.rpc('suspension_status', { uid })` (service role); an error
 * throws, so a write is never let through unchecked.
 */
export async function readSuspension(
  call: PromiseLike<{ data: unknown; error: unknown }>,
): Promise<Suspension> {
  const { data, error } = await call;
  if (error) throw new Error('suspension status unavailable');
  return parseSuspension(data);
}
