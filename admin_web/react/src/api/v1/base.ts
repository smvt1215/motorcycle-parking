import { createApi, type BaseQueryFn } from '@reduxjs/toolkit/query/react';

/**
 * Where the unified API lives and who is calling (#195). Injected through
 * the store's thunk extra argument; null until the admin connects to a
 * backend (production builds have none yet).
 */
export interface PostgrestConnection {
  /** Supabase project URL, e.g. https://xyz.supabase.co */
  url: string;
  /** The public anon key: PostgREST's `apikey` header. */
  anonKey: string;
  /** The signed-in user's access token, or null to call as anon. */
  accessToken: () => string | null | Promise<string | null>;
}

/** What the generated endpoints hand the base query (codegen output). */
export interface PostgrestArgs {
  url: string;
  method?: string;
  body?: unknown;
}

/**
 * An API failure, as #195 §2.4 defines it: `code` is the SQLSTATE (PTxyz for
 * the API's own errors, so `status` is xyz), `message` the stable error code
 * clients choose their wording by (e.g. `auth.aal2_required`).
 */
export interface V1Error {
  status: number;
  code: string;
  message: string;
  details: string | null;
}

export type V1Profile = 'api_v1' | 'admin_v1';

function connectionOf(extra: unknown): PostgrestConnection | null {
  return (extra as { postgrest?: PostgrestConnection | null } | undefined)?.postgrest ?? null;
}

/** A PostgREST RPC call with the schema chosen by Content-Profile. */
export function postgrestBaseQuery(profile: V1Profile): BaseQueryFn<PostgrestArgs, unknown, V1Error> {
  return async (args, api) => {
    const connection = connectionOf(api.extra);
    if (!connection) {
      return {
        error: { status: 0, code: 'client.not_connected', message: 'client.not_connected', details: null },
      };
    }
    const token = (await connection.accessToken()) ?? connection.anonKey;
    let response: Response;
    try {
      response = await fetch(`${connection.url.replace(/\/$/, '')}/rest/v1${args.url}`, {
        method: args.method ?? 'POST',
        headers: {
          apikey: connection.anonKey,
          Authorization: `Bearer ${token}`,
          'Content-Profile': profile,
          'Accept-Profile': profile,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify(args.body ?? {}),
        signal: api.signal,
      });
    } catch (failure) {
      return {
        error: {
          status: 0,
          code: 'client.network',
          message: 'client.network',
          details: failure instanceof Error ? failure.message : String(failure),
        },
      };
    }
    const text = await response.text();
    const json: unknown = text ? JSON.parse(text) : null;
    if (!response.ok) {
      const body = (json ?? {}) as Partial<{ code: string; message: string; details: string | null }>;
      return {
        error: {
          status: response.status,
          code: body.code ?? String(response.status),
          message: body.message ?? 'client.unknown',
          details: body.details ?? null,
        },
      };
    }
    return { data: json };
  };
}

/** Base for api_v1; src/api/v1/api_v1.generated.ts injects its endpoints. */
export const apiV1Base = createApi({
  reducerPath: 'apiV1',
  baseQuery: postgrestBaseQuery('api_v1'),
  endpoints: () => ({}),
});

/** Base for admin_v1; src/api/v1/admin_v1.generated.ts injects its endpoints. */
export const adminV1Base = createApi({
  reducerPath: 'adminV1',
  baseQuery: postgrestBaseQuery('admin_v1'),
  endpoints: () => ({}),
});
