// RTK Query endpoints for the public pages, from the unified API document
// supabase/api/v1/api_v1.json (#195). Only the functions these pages call
// are generated; CI fails when src/api/api_v1.generated.ts differs from what
// the document produces.
import { generateEndpoints } from '@rtk-query/codegen-openapi';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
// apiFile is resolved from the working directory; the output imports it relatively.
process.chdir(root);

/** The account-deletion functions (#270) the deletion page calls. */
const ENDPOINTS = ['apiV1AccountDeletionStatus', 'apiV1RequestAccountDeletion', 'apiV1CancelAccountDeletion'];

// Every PostgREST RPC is a POST, which the generator reads as a mutation.
const READS = ['apiV1AccountDeletionStatus'];

await generateEndpoints({
  schemaFile: `${root}../supabase/api/v1/api_v1.json`,
  apiFile: './src/api/base.ts',
  apiImport: 'apiV1Base',
  outputFile: `${root}src/api/api_v1.generated.ts`,
  exportName: 'apiV1',
  hooks: true,
  filterEndpoints: ENDPOINTS,
  endpointOverrides: READS.map((name) => ({ pattern: name, type: 'query' })),
});
