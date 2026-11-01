// The Resend implementation of Notifier (T269_Q4_MAILER: Resend,
// PM_ANS_20261101_124). RESEND_API_KEY, SUPPORT_MAIL_FROM (a sender on a
// domain verified in Resend) and SUPPORT_MAIL_TO (the support inbox, comma
// separated) come from the environment (#262). Missing any of them: no mail
// is sent and the admin page is where new requests show.
import { type Notifier, silentNotifier } from './handler.ts';

export const resendUrl = 'https://api.resend.com/emails';

export type ResendConfig = { apiKey: string; from: string; to: string[] };

export function resendConfig(
  env: (name: string) => string | undefined,
): ResendConfig | null {
  const apiKey = env('RESEND_API_KEY')?.trim(),
    from = env('SUPPORT_MAIL_FROM')?.trim();
  const to = (env('SUPPORT_MAIL_TO') ?? '').split(',').map((a) => a.trim())
    .filter((a) => a !== '');
  if (!apiKey || !from || to.length === 0) return null;
  return { apiKey, from, to };
}

/** The notice: the request id and the admin page link, nothing else. */
export function noticeMail(id: string, adminUrl: string) {
  return {
    subject: `【機車停車指南】新的客服申請 ${id.slice(0, 8)}`,
    text: [
      '有一筆新的客服申請（刪除帳號）。',
      '',
      `申請編號：${id}`,
      `處理：${adminUrl}`,
      '',
      '申請內容與聯絡方式只在管理站顯示，本信不含個人資料。',
    ].join('\n'),
  };
}

export function resendNotifier(
  config: ResendConfig | null,
  fetcher: typeof fetch = fetch,
): Notifier {
  if (!config) return silentNotifier;
  return {
    async notify({ id, adminUrl }) {
      const res = await fetcher(resendUrl, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${config.apiKey}`,
          'Content-Type': 'application/json',
          // A retry of the same notice is not sent twice (kept 24 hours).
          'Idempotency-Key': `support-request/${id}`,
        },
        body: JSON.stringify({
          from: config.from,
          to: config.to,
          ...noticeMail(id, adminUrl),
        }),
        signal: AbortSignal.timeout(10_000),
      });
      await res.body?.cancel();
      if (!res.ok) throw new Error(`resend ${res.status}`);
      return true;
    },
  };
}
