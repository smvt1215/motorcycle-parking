import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { response } from '../_shared/http.ts';
import { avatarBucket, type Claimed, handle } from './handler.ts';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) return response({ error: 'not configured' }, 503);
  const db = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    secret: Deno.env.get('ACCOUNT_DELETION_SECRET') ?? '',
    async claim(limit) {
      const { data, error } = await db.rpc('account_deletion_claim', {
        p_limit: limit,
      });
      if (error) throw error;
      return (data ?? []) as Claimed[];
    },
    async prepare(request) {
      const { data, error } = await db.rpc('account_deletion_prepare', {
        p_request: request,
      });
      if (error) throw error;
      return data as Record<string, number> | null;
    },
    async listAvatars(user, limit) {
      const { data, error } = await db.storage.from(avatarBucket).list(user, {
        limit,
        offset: 0,
      });
      if (error) throw error;
      // Files only: avatars sit directly under the account's folder.
      return (data ?? []).filter((item) => item.id !== null).map((item) =>
        item.name
      );
    },
    async removeAvatars(paths) {
      const { error } = await db.storage.from(avatarBucket).remove(paths);
      if (error) throw error;
    },
    async deleteUser(user) {
      // A hard delete: the row goes, so the foreign keys anonymise and
      // delete the account's data and its sessions end.
      const { error } = await db.auth.admin.deleteUser(user, false);
      if (error) throw error;
    },
    async finish(request, source, counts) {
      const { error } = await db.rpc('account_deletion_finish', {
        p_request: request,
        p_source: source,
        p_counts: counts,
      });
      if (error) throw error;
    },
    async fail(request, code) {
      const { error } = await db.rpc('account_deletion_fail', {
        p_request: request,
        p_error: code,
      });
      if (error) throw error;
    },
  });
});
