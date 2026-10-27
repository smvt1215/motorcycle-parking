import { createClient } from 'npm:@supabase/supabase-js@2.108.1';
import { identityHash } from '../submit-report/validate.ts';
import { handle } from './handler.ts';

/** The audit log's actor for bans the rules make, not an admin. */
const systemActor = '00000000-0000-0000-0000-000000000000';

Deno.serve((req) => {
  const url = Deno.env.get('SUPABASE_URL'),
    key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const secret = Deno.env.get('REPORT_HASH_SECRET'),
    header = Deno.env.get('TRUSTED_IP_HEADER');
  if (!url || !key || !secret) return handle(req, null, null);
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handle(req, {
    async user(token) {
      const { data, error } = await admin.auth.getUser(token);
      if (error || !data.user) return null;
      return { id: data.user.id, anonymous: data.user.is_anonymous === true };
    },
    hash: (value) => identityHash(secret, value),
    async apply({ user, ip, device, sighting }) {
      const { data, error } = await admin.rpc('apply_sighting', {
        p_user: user,
        p_ip: ip,
        p_device: device,
        p_spot: sighting.spot_id,
        p_kind: sighting.kind,
        p_vehicle: sighting.vehicle,
      });
      return { data, error };
    },
    async ban(user, duration) {
      const { data, error } = await admin.auth.admin.updateUserById(user, {
        ban_duration: duration,
      });
      if (error || !data.user) throw error ?? new Error('no user');
      return data.user.banned_until ?? null;
    },
    async record({ user, after, duration, note }) {
      const { error } = await admin.rpc('admin_record_user_ban', {
        p_actor: systemActor,
        p_user: user,
        p_action: 'ban_user',
        p_before: null,
        p_after: after,
        p_duration: duration,
        p_note: note,
      });
      if (error) throw error;
    },
  }, header ?? null);
});
