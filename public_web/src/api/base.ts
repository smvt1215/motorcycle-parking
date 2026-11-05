import { createApi, type BaseQueryFn } from '@reduxjs/toolkit/query/react';

/**
 * Where the unified API lives and who is calling (#195). Injected through
 * the store's thunk extra argument; null when the build has no backend
 * configured (the page then explains instead of signing in).
 */
export interface PostgrestConnection {
  /** Supabase project URL, e.g. https://xyz.supabase.co */
  url: string;
  /** The publishable key: PostgREST's `apikey` header. */
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
 * the page chooses its wording by (e.g. `auth.recent_sign_in_required`).
 * Failures before an answer arrives use `client.*` codes.
 */
export interface V1Error {
  status: number;
  code: string;
  message: string;
  details: string | null;
}

function connectionOf(extra: unknown): PostgrestConnection | null {
  return (extra as { postgrest?: PostgrestConnection | null } | undefined)?.postgrest ?? null;
}

function clientError(status: number, code: string, details: string | null): { error: V1Error } {
  return { error: { status, code, message: code, details } };
}

/** A PostgREST RPC call in the api_v1 schema (same contract as the admin's). */
export const postgrestBaseQuery: BaseQueryFn<PostgrestArgs, unknown, V1Error> = async (args, api) => {
  const connection = connectionOf(api.extra);
  if (!connection) return clientError(0, 'client.not_connected', null);
  const token = (await connection.accessToken()) ?? connection.anonKey;
  let response: Response;
  try {
    response = await fetch(`${connection.url.replace(/\/$/, '')}/rest/v1${args.url}`, {
      method: args.method ?? 'POST',
      headers: {
        apikey: connection.anonKey,
        Authorization: `Bearer ${token}`,
        'Content-Profile': 'api_v1',
        'Accept-Profile': 'api_v1',
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify(args.body ?? {}),
      signal: api.signal,
    });
  } catch (failure) {
    return clientError(0, 'client.network', failure instanceof Error ? failure.message : String(failure));
  }
  // The body can fail to arrive, or be a gateway's HTML page (a 502):
  // both still end as a V1Error that keeps the HTTP status.
  let text: string;
  try {
    text = await response.text();
  } catch (failure) {
    return clientError(
      response.status,
      'client.network',
      failure instanceof Error ? failure.message : String(failure),
    );
  }
  let json: unknown = null;
  let parsed = true;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    parsed = false;
  }
  if (!response.ok) {
    const body = (parsed && json !== null && typeof json === 'object' ? json : {}) as Partial<V1Error>;
    return {
      error: {
        status: response.status,
        code: body.code ?? String(response.status),
        message: body.message ?? 'client.unknown',
        details: body.details ?? (parsed ? null : text.slice(0, 200)),
      },
    };
  }
  if (!parsed) return clientError(response.status, 'client.bad_response', text.slice(0, 200));
  return { data: json };
};

/** Base for api_v1; src/api/api_v1.generated.ts injects its endpoints. */
export const apiV1Base = createApi({
  reducerPath: 'apiV1',
  baseQuery: postgrestBaseQuery,
  endpoints: () => ({}),
});
