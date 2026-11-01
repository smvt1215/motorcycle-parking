import { makeStore } from '../../app/store';
import { apiV1 } from './api_v1.generated';
import type { PostgrestConnection } from './base';

const connection = (token: string | null = null): PostgrestConnection => ({
  url: 'https://example.supabase.co/',
  anonKey: 'anon-key',
  accessToken: () => token,
});

function respond(status: number, body: unknown) {
  const fetchMock = vi.fn(async () => new Response(JSON.stringify(body), { status }));
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

afterEach(() => vi.unstubAllGlobals());

describe('postgrestBaseQuery through the generated api_v1 endpoints', () => {
  it('posts the RPC to PostgREST with the schema profile and the anon key', async () => {
    const fetchMock = respond(200, {
      min_supported_app_version: '0.1.0',
      rules_version: 25,
      spots_version: 808,
    });
    const store = makeStore({ postgrest: connection() });
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());

    expect(result.data).toEqual({
      min_supported_app_version: '0.1.0',
      rules_version: 25,
      spots_version: 808,
    });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('https://example.supabase.co/rest/v1/rpc/client_config');
    expect(init.method).toBe('POST');
    expect(init.body).toBe('{}');
    expect(init.headers).toMatchObject({
      apikey: 'anon-key',
      Authorization: 'Bearer anon-key',
      'Content-Profile': 'api_v1',
      'Accept-Profile': 'api_v1',
    });
  });

  it('sends the signed-in user token when there is one', async () => {
    const fetchMock = respond(200, {
      min_supported_app_version: '0.1.0',
      rules_version: 1,
      spots_version: 1,
    });
    const store = makeStore({ postgrest: connection('user-token') });
    await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(init.headers).toMatchObject({ Authorization: 'Bearer user-token', apikey: 'anon-key' });
  });

  it('turns a PostgREST error into the stable error code (#195 §2.4)', async () => {
    respond(403, { code: 'PT403', message: 'auth.aal2_required', details: '{"reason":"x"}', hint: null });
    const store = makeStore({ postgrest: connection() });
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    expect(result.error).toEqual({
      status: 403,
      code: 'PT403',
      message: 'auth.aal2_required',
      details: '{"reason":"x"}',
    });
  });

  it('says so when no backend is connected, without calling anything', async () => {
    const fetchMock = respond(200, {});
    const store = makeStore();
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    expect(result.error).toMatchObject({ code: 'client.not_connected' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('reports a network failure as client.network', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new TypeError('Failed to fetch');
      }),
    );
    const store = makeStore({ postgrest: connection() });
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    expect(result.error).toMatchObject({ status: 0, code: 'client.network', details: 'Failed to fetch' });
  });

  it('keeps the HTTP status when a gateway answers with HTML', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('<html>502 Bad Gateway</html>', { status: 502 })),
    );
    const store = makeStore({ postgrest: connection() });
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    expect(result.error).toEqual({
      status: 502,
      code: '502',
      message: 'client.unknown',
      details: '<html>502 Bad Gateway</html>',
    });
  });

  it('reports a success that is not JSON as client.bad_response', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('not json', { status: 200 })),
    );
    const store = makeStore({ postgrest: connection() });
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    expect(result.error).toMatchObject({ status: 200, code: 'client.bad_response' });
  });

  it('reports a body cut off after the headers as client.network with the status', async () => {
    const response = new Response('{}', { status: 200 });
    vi.spyOn(response, 'text').mockRejectedValue(new TypeError('network error'));
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => response),
    );
    const store = makeStore({ postgrest: connection() });
    const result = await store.dispatch(apiV1.endpoints.apiV1ClientConfig.initiate());
    expect(result.error).toMatchObject({ status: 200, code: 'client.network', details: 'network error' });
  });
});
