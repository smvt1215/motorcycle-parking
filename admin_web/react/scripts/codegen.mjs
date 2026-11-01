// RTK Query endpoints from the unified API documents (#195 P1).
// `npm run codegen` writes src/api/v1/<schema>.generated.ts from
// supabase/api/v1/<schema>.json; CI fails when they differ from what the
// documents produce. The CLI takes one config per run, so each schema is
// generated here in turn.
import { generateEndpoints } from '@rtk-query/codegen-openapi';
import { readFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
// apiFile is resolved from the working directory; outputs import it relatively.
process.chdir(root);

// Every PostgREST RPC is a POST, which the generator reads as a mutation.
// Read-only API functions are listed here as queries (cached, refetchable),
// by their generated endpoint name.
const READS = {
  api_v1: ['apiV1ClientConfig', 'apiV1CityRules', 'apiV1AccountDeletionStatus'],
  admin_v1: [],
};

const PROFILES = [
  { schema: 'api_v1', exportName: 'apiV1', apiImport: 'apiV1Base' },
  { schema: 'admin_v1', exportName: 'adminV1', apiImport: 'adminV1Base' },
];

for (const { schema, exportName, apiImport } of PROFILES) {
  const outputFile = `${root}src/api/v1/${schema}.generated.ts`;
  const document = JSON.parse(readFileSync(`${root}../../supabase/api/v1/${schema}.json`, 'utf8'));
  // A schema without functions yet generates nothing: the base alone is
  // registered in the store, and an empty endpoints() would not compile.
  if (Object.keys(document.paths).length === 0) {
    rmSync(outputFile, { force: true });
    continue;
  }
  await generateEndpoints({
    schemaFile: `${root}../../supabase/api/v1/${schema}.json`,
    apiFile: './src/api/v1/base.ts',
    apiImport,
    outputFile,
    exportName,
    hooks: true,
    endpointOverrides: READS[schema].map((name) => ({ pattern: name, type: 'query' })),
  });
}
