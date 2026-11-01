// check_responses.ts against a fake PostgREST (no stack needed).
import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1.0.19';
import { check, type Document } from './check_responses.ts';

const served = {
  min_supported_app_version: '0.1.0',
  rules_version: 25,
  spots_version: 808,
};

function answering(status: number, body: unknown) {
  const seen: { url: string; profile: string | null; body: string }[] = [];
  const fetcher = (input: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    seen.push({
      url: String(input),
      profile: headers.get('Content-Profile'),
      body: String(init?.body),
    });
    return Promise.resolve(
      new Response(typeof body === 'string' ? body : JSON.stringify(body), {
        status,
      }),
    );
  };
  return { fetcher: fetcher as typeof fetch, seen };
}

Deno.test('a documented answer passes and each function is called in its schema', async () => {
  const { fetcher, seen } = answering(200, served);
  assertEquals(await check('http://127.0.0.1:54321/', 'anon', fetcher), []);
  assertEquals(seen[0], {
    url: 'http://127.0.0.1:54321/rest/v1/rpc/client_config',
    profile: 'api_v1',
    body: '{}',
  });
});

Deno.test('an answer that drifted from the document fails', async () => {
  for (
    const body of [
      { ...served, rules_version: '25' },
      { ...served, extra: true },
      { rules_version: 25, spots_version: 808 },
    ]
  ) {
    const problems = await check(
      'http://x',
      'anon',
      answering(200, body).fetcher,
    );
    assertEquals(problems.length, 1);
    assertStringIncludes(problems[0], 'api_v1 /rpc/client_config: data');
  }
});

Deno.test('a public function refusing anon fails with the answer', async () => {
  const problems = await check(
    'http://x',
    'anon',
    answering(406, { code: 'PGRST106', message: 'Invalid schema: api_v1' })
      .fetcher,
  );
  assertEquals(problems.length, 1);
  assertStringIncludes(problems[0], 'anon should be allowed, got 406');
});

Deno.test('a body that is not JSON fails', async () => {
  const problems = await check(
    'http://x',
    'anon',
    answering(502, '<html>Bad Gateway</html>').fetcher,
  );
  assertStringIncludes(problems[0], '502 is not JSON: <html>');
});

Deno.test('an admin function must refuse anon with a documented error', async () => {
  const admin = JSON.parse(
    await Deno.readTextFile(new URL('admin_v1.json', import.meta.url)),
  );
  admin.paths['/rpc/review_queue'] = {
    post: {
      operationId: 'admin_v1_review_queue',
      responses: {
        '200': {
          content: { 'application/json': { schema: { type: 'array' } } },
        },
        default: { $ref: '#/components/responses/Error' },
      },
    },
  };
  const load = (schema: string): Promise<Document> =>
    schema === 'admin_v1'
      ? Promise.resolve(admin)
      : Promise.resolve({ paths: {} });
  const refused = {
    code: 'PT403',
    message: 'auth.admin_required',
    details: null,
    hint: null,
  };
  assertEquals(
    await check('http://x', 'anon', answering(403, refused).fetcher, load),
    [],
  );
  const [let_in] = await check(
    'http://x',
    'anon',
    answering(200, []).fetcher,
    load,
  );
  assertStringIncludes(
    let_in,
    'admin_v1 /rpc/review_queue: anon should be refused, got 200',
  );
  const [bad] = await check(
    'http://x',
    'anon',
    answering(403, { error: 'x' }).fetcher,
    load,
  );
  assertStringIncludes(bad, "must have required property 'code'");
});

Deno.test('a function with parameters needs an example to be called', async () => {
  const api = JSON.parse(
    await Deno.readTextFile(new URL('api_v1.json', import.meta.url)),
  );
  api.paths['/rpc/client_config'].post.requestBody = {
    content: { 'application/json': { schema: { type: 'object' } } },
  };
  const load = (schema: string): Promise<Document> =>
    schema === 'api_v1' ? api : Promise.resolve({ paths: {} });
  const [problem] = await check(
    'http://x',
    'anon',
    answering(200, served).fetcher,
    load,
  );
  assertStringIncludes(problem, 'needs an example');
});
