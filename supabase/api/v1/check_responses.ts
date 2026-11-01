// Calls every function in supabase/api/v1/<schema>.json on a running stack
// and validates the answer against the document (#195 P1), so the documents
// and the SQL cannot drift apart unnoticed. Read-only: run it after
// `supabase start` with the stack's API URL and anon key.
//
//   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=... \
//     deno run --allow-read=. --allow-env --allow-net check_responses.ts
//
// Calls are made as anon. api_v1 must answer 200 with the documented body.
// admin_v1 must refuse anon, and the refusal must be a documented ApiError.
// An operation with parameters is called with its request schema's `example`.
import { Ajv2020 } from 'npm:ajv@8.17.1/dist/2020.js';

type Operation = {
  operationId: string;
  requestBody?: {
    content: { 'application/json': { schema: { example?: unknown } } };
  };
};
export type Document = { paths: Record<string, { post: Operation }> };

const SCHEMAS = { api_v1: 'allowed', admin_v1: 'refused' } as const;
const DIR = new URL('.', import.meta.url);

/** `~` and `/` are escaped in a JSON pointer token. */
const token = (key: string) => key.replaceAll('~', '~0').replaceAll('/', '~1');

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
  // The documents carry OpenAPI keys (openapi, paths, x-*) next to schemas.
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  const problems: string[] = [];
  for (const [schema, anon] of Object.entries(SCHEMAS)) {
    const id = `https://motorcycle-parking.local/api/v1/${schema}.json`;
    const document = await load(schema);
    ajv.addSchema({ ...document, $id: id });
    for (const [path, { post }] of Object.entries(document.paths)) {
      const where = `${schema} ${path}`;
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
      let body: unknown;
      try {
        body = JSON.parse(text);
      } catch {
        problems.push(
          `${where}: ${response.status} is not JSON: ${text.slice(0, 200)}`,
        );
        continue;
      }
      const ok = anon === 'allowed';
      if (response.ok !== ok) {
        problems.push(
          `${where}: anon should be ${anon}, got ${response.status} ${
            text.slice(0, 200)
          }`,
        );
        continue;
      }
      const pointer = [
        'paths',
        path,
        'post',
        'responses',
        ok ? '200' : 'default',
      ].map(token).join('/');
      // default points at components/responses/Error, whose content holds the schema.
      const target = ok
        ? `${id}#/${pointer}/content/application~1json/schema`
        : `${id}#/components/responses/Error/content/application~1json/schema`;
      const validate = ajv.compile({ $ref: target });
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
