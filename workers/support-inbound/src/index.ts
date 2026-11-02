// support-inbound Email Worker (#295 layer 2; PM_ANS_20261101_147).
// Cloudflare Email Routing sends support@ and reply@ (with subaddressing,
// so reply+<token>@) here. The Worker parses the mail in memory, posts the
// parts a case needs to the Edge Function support-inbound with an HMAC
// signature, and keeps nothing: the raw mail is never stored or forwarded.
// ops@ is a plain Email Routing forward and never reaches this Worker.
//
// Settings (docs/CD_SETUP.md): SUPPORT_INBOUND_URL and AUTHSERV_ID as vars,
// SUPPORT_INBOUND_SECRET as a secret (wrangler secret put).
import PostalMime from 'postal-mime';
import {
  accepts,
  defaultAuthservId,
  maxRawSize,
  payload,
  rawDigest,
  signedRequest,
} from './inbound.ts';

type Env = {
  SUPPORT_INBOUND_URL: string;
  SUPPORT_INBOUND_SECRET: string;
  AUTHSERV_ID?: string;
};

type IncomingMail = {
  readonly from: string;
  readonly to: string;
  readonly raw: ReadableStream;
  readonly rawSize: number;
  setReject(reason: string): void;
};

export default {
  async email(message: IncomingMail, env: Env): Promise<void> {
    if (!accepts(message.to)) {
      message.setReject('Unknown address');
      return;
    }
    if (message.rawSize > maxRawSize) {
      message.setReject('Message too large; please use the support form');
      return;
    }
    if (!env.SUPPORT_INBOUND_URL || !env.SUPPORT_INBOUND_SECRET) {
      // A temporary failure: the sending server retries later.
      throw new Error('support-inbound is not configured');
    }
    // At most 5 MB, read once: hashed for filing it once, then parsed.
    const raw = await new Response(message.raw).arrayBuffer();
    let parsed;
    try {
      parsed = await PostalMime.parse(raw);
    } catch {
      // A broken mail stays broken: bounce it rather than have it retried.
      message.setReject('This message could not be read');
      return;
    }
    const res = await fetch(
      await signedRequest(
        env.SUPPORT_INBOUND_URL,
        env.SUPPORT_INBOUND_SECRET,
        payload(
          message.to,
          message.from,
          parsed,
          env.AUTHSERV_ID || defaultAuthservId,
          await rawDigest(raw),
        ),
      ),
    );
    await res.body?.cancel();
    // Only a 400 (a mail support-inbound cannot take) bounces. Anything else
    // (a 401/403 from a secret out of step or a clock off, a 404 before the
    // function is deployed, a 5xx) is thrown, so the sending server retries
    // instead of the mail being lost (cross review, PR #306).
    if (res.status === 400) {
      message.setReject('This message could not be filed');
      return;
    }
    if (!res.ok) throw new Error(`support-inbound ${res.status}`);
  },
};
