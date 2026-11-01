import {
  type AppCheckMode,
  appCheckRefuses,
  type AppCheckResult,
  appCheckToken,
} from '../_shared/app_check.ts';

/** What App Check decides for one report (#203). */
export interface AppCheckGate {
  /** Refuse with 401: only when APP_CHECK_MODE is enforce and not valid. */
  refused: boolean;
  /**
   * Whether apply_report() hard-caps the network at 200 a day: while App
   * Check only logs (or is off). Once it is enforced the network count is a
   * risk signal instead.
   */
  ipCapped: boolean;
}

/**
 * The App Check verdict on a report request. Off skips verification; log
 * and enforce verify the X-Firebase-AppCheck token and log the outcome
 * (never the token, the user or the network).
 */
export async function appCheckGate(
  req: Request,
  mode: AppCheckMode,
  verify: (token: string | null) => Promise<AppCheckResult | null>,
): Promise<AppCheckGate> {
  const ipCapped = mode !== 'enforce';
  if (mode === 'off') return { refused: false, ipCapped };
  const verdict = await verify(appCheckToken(req));
  return { refused: appCheckRefuses('submit-report', mode, verdict), ipCapped };
}
