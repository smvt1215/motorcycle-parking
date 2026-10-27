import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { handle } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return response({ error: 'not configured' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    secret: Deno.env.get('AVAILABILITY_INGEST_SECRET') ?? '',
    now: () => new Date(),
    fetch: (url, init) => fetch(url, init),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    async source(key) {
      const { data, error } = await db
        .from('availability_sources')
        .select(
          'key,enabled,feed_url,capacity_url,etag,next_attempt_at,capacity_updated_at',
        )
        .eq('key', key)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    async storeCapacities(key, rows) {
      const { error } = await db.rpc('availability_store_capacities', {
        p_source: key,
        p_rows: rows,
      });
      if (error) throw error;
    },
    async ingest(key, updatedAt, parks, etag) {
      const { data, error } = await db.rpc('availability_ingest', {
        p_source: key,
        p_source_updated_at: updatedAt.toISOString(),
        p_parks: parks,
        p_etag: etag,
      });
      if (error) throw error;
      return data;
    },
    async record(key, outcome, message) {
      const { error } = await db.rpc('availability_record_run', {
        p_source: key,
        p_outcome: outcome,
        p_message: message,
      });
      if (error) throw error;
    },
  });
});
