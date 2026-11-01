// check_responses.ts against a fake PostgREST (no stack needed).
import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1.0.19';
import { check, type Document } from './check_responses.ts';

const served = {
  min_supported_app_version: '0.1.0',
  rules_version: 25,
  spots_version: 808,
  availability_beta_cities: ['臺北市'],
};

/** The real api_v1.json with only client_config, which `served` answers. */
async function clientConfigOnly() {
  const api = JSON.parse(
    await Deno.readTextFile(new URL('api_v1.json', import.meta.url)),
  );
  api.paths = { '/rpc/client_config': api.paths['/rpc/client_config'] };
  return api;
}
const clientConfigLoad = async (schema: string): Promise<Document> =>
  schema === 'api_v1' ? await clientConfigOnly() : { paths: {} };

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
  assertEquals(
    await check('http://127.0.0.1:54321/', 'anon', fetcher, clientConfigLoad),
    [],
  );
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
      clientConfigLoad,
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
    clientConfigLoad,
  );
  assertEquals(problems.length, 1);
  assertStringIncludes(problems[0], 'anon should be allowed, got 406');
});

Deno.test('a body that is not JSON fails', async () => {
  const problems = await check(
    'http://x',
    'anon',
    answering(502, '<html>Bad Gateway</html>').fetcher,
    clientConfigLoad,
  );
  assertStringIncludes(problems[0], '502 is not JSON: <html>');
});

Deno.test('an admin function must refuse anon with a documented error', async () => {
  const admin = JSON.parse(
    await Deno.readTextFile(new URL('admin_v1.json', import.meta.url)),
  );
  // Only this test's function, whatever admin_v1.json grows to.
  admin.paths = {};
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
    code: '42501',
    message: 'permission denied for schema admin_v1',
    details: null,
    hint: null,
  };
  assertEquals(
    await check('http://x', 'anon', answering(401, refused).fetcher, load),
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
    'admin_v1 /rpc/review_queue: anon should be refused with 401 42501, got 200',
  );
  // A function the SQL does not have, or a schema PostgREST does not serve,
  // is an error too, but not the refusal (cross review, PR #236).
  for (
    const [status, error] of [
      [404, { code: 'PGRST202', message: 'Could not find the function' }],
      [406, { code: 'PGRST106', message: 'Invalid schema: admin_v1' }],
    ] as const
  ) {
    const [wrong] = await check(
      'http://x',
      'anon',
      answering(status, { ...error, details: null, hint: null }).fetcher,
      load,
    );
    assertStringIncludes(wrong, `got ${status}`);
  }
  const [bad] = await check(
    'http://x',
    'anon',
    answering(401, { code: '42501' }).fetcher,
    load,
  );
  assertStringIncludes(bad, "must have required property 'message'");
});

Deno.test('a function with parameters needs an example to be called', async () => {
  const api = await clientConfigOnly();
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

Deno.test('a function with parameters is called with its example', async () => {
  const api = await clientConfigOnly();
  api.paths['/rpc/client_config'].post.requestBody = {
    content: {
      'application/json': {
        schema: {
          type: 'object',
          properties: { p_id: { type: 'integer' } },
          example: { p_id: 1 },
        },
      },
    },
  };
  const load = (schema: string): Promise<Document> =>
    Promise.resolve(schema === 'api_v1' ? api : { paths: {} });
  const { fetcher, seen } = answering(200, served);
  assertEquals(await check('http://x', 'anon', fetcher, load), []);
  assertEquals(seen[0].body, '{"p_id":1}');
});

Deno.test('a document that cannot be checked fails instead of passing', async () => {
  const api = await clientConfigOnly();
  const load = (schema: string): Promise<Document> =>
    Promise.resolve(schema === 'api_v1' ? api : { paths: {} });
  const config = api.components.schemas.ClientConfig.properties;
  // A misspelt keyword would otherwise validate nothing.
  config.rules_version = { tpye: 'integer' };
  const [misspelt] = await check(
    'http://x',
    'anon',
    answering(200, served).fetcher,
    load,
  );
  assertStringIncludes(misspelt, 'does not compile');
  config.rules_version = { type: 'integer' };
  // No 200 body schema, and no 200 at all.
  delete api.paths['/rpc/client_config'].post.responses['200'].content;
  const [noBody] = await check(
    'http://x',
    'anon',
    answering(200, served).fetcher,
    load,
  );
  assertStringIncludes(noBody, 'does not compile');
  delete api.paths['/rpc/client_config'].post.responses['200'];
  const [none] = await check(
    'http://x',
    'anon',
    answering(200, served).fetcher,
    load,
  );
  assertStringIncludes(none, 'the document gives no 200 response');
});
