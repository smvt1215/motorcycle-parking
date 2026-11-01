// Calls every function in supabase/api/v1/<schema>.json on a running stack
// and validates the answer against the document (#195 P1), so the documents
// and the SQL cannot drift apart unnoticed. Read-only: run it after
// `supabase start` with the stack's API URL and anon key.
//
//   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... \
//     deno run --allow-read=. --allow-env --allow-net check_responses.ts
//
// Calls are made as anon. api_v1 must answer 200 with the documented body.
// admin_v1 must refuse anon the way private.require_admin() does (403
// auth.aal2_required), with the error its document gives: any other error,
// such as 404 for a function the SQL does not have, fails.
// An operation with parameters is called with its request schema's `example`.
import { Ajv2020 } from 'npm:ajv@8.17.1/dist/2020.js';

type Response = { $ref?: string; content?: unknown };
type Operation = {
  operationId: string;
  requestBody?: {
    content: { 'application/json': { schema: { example?: unknown } } };
  };
  responses?: Record<string, Response>;
};
export type Document = { paths: Record<string, { post: Operation }> };

const SCHEMAS = { api_v1: 'allowed', admin_v1: 'refused' } as const;
const DIR = new URL('.', import.meta.url);
/** How private.require_admin() refuses anyone who is not a signed-in admin. */
const REFUSAL = { status: 403, message: 'auth.aal2_required' };
// Keys of an OpenAPI document that are not JSON Schema keywords. Strict mode
// stays on so a misspelt keyword or an unknown format fails instead of
// quietly validating nothing (cross review, PR #236); add new keys here.
const OPENAPI_KEYS = [
  'openapi',
  'info',
  'servers',
  'paths',
  'components',
  'example',
  'x-content-profile',
];

/** `~` and `/` are escaped in a JSON pointer token. */
const token = (key: string) => key.replaceAll('~', '~0').replaceAll('/', '~1');

/**
 * The pointer to a documented response's body schema: inline, or through a
 * `#/components/responses/...` reference. Null when there is none.
 */
function schemaPointer(response: Response | undefined, at: string[]) {
  if (!response) return null;
  const base = response.$ref?.startsWith('#/')
    ? response.$ref.slice(2)
    : at.map(token).join('/');
  return `${base}/content/application~1json/schema`;
}

function refusedAsAdmin(status: number, body: unknown) {
  return status === REFUSAL.status &&
    typeof body === 'object' && body !== null &&
    (body as { message?: unknown }).message === REFUSAL.message;
}

const readDocument = async (schema: string) =>
  JSON.parse(
    await Deno.readTextFile(new URL(`${schema}.json`, DIR)),
  ) as Document;

export async function check(
  url: string,
  anonKey: string,
  fetcher = fetch,
  load: (schema: string) => Promise<Document> = readDocument,
): Promise<string[]> {
  const ajv = new Ajv2020({ strict: true, allErrors: true });
  ajv.addVocabulary(OPENAPI_KEYS);
  const problems: string[] = [];
  for (const [schema, anon] of Object.entries(SCHEMAS)) {
    const id = `https://motorcycle-parking.local/api/v1/${schema}.json`;
    const document = await load(schema);
    ajv.addSchema({ ...document, $id: id });
    for (const [path, { post }] of Object.entries(document.paths)) {
      const where = `${schema} ${path}`;
      const ok = anon === 'allowed';
      const status = ok ? '200' : 'default';
      const pointer = schemaPointer(post.responses?.[status], [
        'paths',
        path,
        'post',
        'responses',
        status,
      ]);
      if (!pointer) {
        problems.push(`${where}: the document gives no ${status} response`);
        continue;
      }
      let validate;
      try {
        validate = ajv.compile({ $ref: `${id}#/${pointer}` });
      } catch (error) {
        problems.push(
          `${where}: the ${status} schema does not compile (${pointer}): ${
            error instanceof Error ? error.message : error
          }`,
        );
        continue;
      }
      const params = post.requestBody?.content['application/json'].schema;
      if (params && !('example' in params)) {
        problems.push(
          `${where}: the request schema needs an example to be called with`,
        );
        continue;
      }
      const response = await fetcher(
        `${url.replace(/\/$/, '')}/rest/v1${path}`,
        {
          method: 'POST',
          headers: {
            apikey: anonKey,
            Authorization: `Bearer ${anonKey}`,
            'Content-Profile': schema,
            'Content-Type': 'application/json',
            Accept: 'application/json',
          },
          body: JSON.stringify(params?.example ?? {}),
        },
      );
      const text = await response.text();
      const shown = `${response.status} ${text.slice(0, 200)}`;
      let body: unknown;
      try {
        body = JSON.parse(text);
      } catch {
        problems.push(
          `${where}: ${response.status} is not JSON: ${text.slice(0, 200)}`,
        );
        continue;
      }
      if (ok && response.status !== 200) {
        problems.push(`${where}: anon should be allowed, got ${shown}`);
        continue;
      }
      if (!ok && !refusedAsAdmin(response.status, body)) {
        problems.push(
          `${where}: anon should be refused with ${REFUSAL.status} ${REFUSAL.message}, got ${shown}`,
        );
        continue;
      }
      if (!validate(body)) {
        problems.push(
          `${where}: ${ajv.errorsText(validate.errors)} in ${
            text.slice(0, 200)
          }`,
        );
      } else {
        console.log(`${where}: ${response.status} matches the document`);
      }
    }
  }
  return problems;
}

if (import.meta.main) {
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !key) {
    console.error(
      'check_responses: SUPABASE_URL and SUPABASE_ANON_KEY are required',
    );
    Deno.exit(2);
  }
  const problems = await check(url, key);
  for (const problem of problems) console.error(`::error::${problem}`);
  Deno.exit(problems.length ? 1 : 0);
}
