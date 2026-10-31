import type { ReviewQueue, ReviewSpot } from './model';

/** What the admin decided; only 「套用建議」 exists until 駁回／修改後套用 are designed. */
export interface ResolveRequest {
  reportId: string;
  decision: 'accepted';
  /** Spot columns to write; built by `applyPatch` (model.ts). */
  patch: Record<string, unknown>;
  note: string;
  /** Write over a spot that changed since the report (after a reload). */
  force: boolean;
}

export interface ResolveResult {
  reportId: string;
  spot: ReviewSpot | null;
}

/**
 * Failures the page can explain. `stale` mirrors `admin_resolve_report`
 * raising 40001 「spot changed since the report」; `alreadyResolved` mirrors
 * 「already resolved」 (another admin got there first).
 */
export type SourceErrorCode = 'stale' | 'alreadyResolved' | 'network' | 'timeout' | 'unknown';

export class SourceError extends Error {
  readonly code: SourceErrorCode;
  constructor(code: SourceErrorCode, message: string) {
    super(message);
    this.code = code;
  }
}

/**
 * The admin's data access. The real implementation calls `admin_v1`
 * (#195); until then only the fixture source exists, for development and
 * tests. The patch is written as given: the Flutter admin merges a fee
 * suggestion with the stored fee and rewrites fee_note on the client, so
 * proposals with structured values are not applied here (see
 * STRUCTURED_KEYS in model.ts) until that logic lives in the shared core.
 */
export interface AdminDataSource {
  loadQueue(): Promise<ReviewQueue>;
  resolve(request: ResolveRequest): Promise<ResolveResult>;
}
