// The Resend implementation of the support mails (T269_Q4_MAILER: Resend,
// PM_ANS_20261101_124). RESEND_API_KEY and SUPPORT_MAIL_FROM (a sender on a
// domain verified in Resend, support@motoparking.smvtstudio.com) come from
// the environment (#262); SUPPORT_MAIL_TO (the support inbox, comma
// separated) for the notice to the administrators. Missing any of them: no
// mail is sent and the admin page is where new requests show.
//
// Mail to riders (#285, PM_ANS_20261101_132): the contact email gets only a
// fixed receipt, the same whether or not an account matched. Everything
// about the account (the confirmation link, the state of an account already
// in the cooling-off period, the notice once the deletion is asked for)
// goes only to the account's login email.
// Cases (#295): support@ receives mail (Cloudflare Email Routing, turned
// into cases), so every mail tells the rider to reply to it or, for a case,
// to open the case link; a case mail's Reply-To is reply+<token>@, which
// lands on the same case.
// Click tracking must stay off for the sending domain in Resend, so the
// one-time link is not rewritten or recorded there.
import {
  type Kind,
  type Notice,
  type Notifier,
  silentNotifier,
} from './handler.ts';

export const resendUrl = 'https://api.resend.com/emails';
export const supportAddress = 'support@motoparking.smvtstudio.com';
export const siteUrl = 'https://motoparking.smvtstudio.com';

export type ResendSender = { apiKey: string; from: string };
export type ResendConfig = ResendSender & { to: string[] };
export type Mail = {
  to: string[];
  subject: string;
  text: string;
  /** The Reply-To address (reply+<token>@ for a case, #295). */
  replyTo?: string;
};

/** The key and the sender: enough for mail to riders. */
export function resendSender(
  env: (name: string) => string | undefined,
): ResendSender | null {
  const apiKey = env('RESEND_API_KEY')?.trim(),
    from = env('SUPPORT_MAIL_FROM')?.trim();
  if (!apiKey || !from) return null;
  return { apiKey, from };
}

export function resendConfig(
  env: (name: string) => string | undefined,
): ResendConfig | null {
  const sender = resendSender(env);
  const to = (env('SUPPORT_MAIL_TO') ?? '').split(',').map((a) => a.trim())
    .filter((a) => a !== '');
  if (!sender || to.length === 0) return null;
  return { ...sender, to };
}

/**
 * Sends one mail; a retry with the same key is not sent twice (24 hours).
 * Resolves to Resend's id for the mail, when it gives one.
 */
export async function sendMail(
  sender: ResendSender,
  mail: Mail,
  idempotencyKey: string,
  fetcher: typeof fetch = fetch,
): Promise<string | null> {
  const { replyTo, ...rest } = mail;
  const res = await fetcher(resendUrl, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${sender.apiKey}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': idempotencyKey,
    },
    body: JSON.stringify({
      from: sender.from,
      ...rest,
      ...(replyTo ? { reply_to: replyTo } : {}),
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`resend ${res.status}`);
  }
  const body = await res.json().catch(() => null) as { id?: unknown } | null;
  return typeof body?.id === 'string' ? body.id.slice(0, 100) : null;
}

/**
 * The notice to ops@ (SUPPORT_MAIL_TO): the case id and the admin page
 * link, nothing else (#295). A rider's reply says so.
 */
export function noticeMail(id: string, adminUrl: string, reply = false) {
  return {
    subject: reply
      ? `【機車停車指南】客服案件有新回覆 ${supportCode(id)}`
      : `【機車停車指南】新的客服案件 ${supportCode(id)}`,
    text: [
      reply ? '客服案件收到使用者的回覆。' : '有一筆新的客服案件。',
      '',
      `案件編號：${id}`,
      `處理：${adminUrl}`,
      '',
      '案件內容與聯絡方式只在管理站顯示，本信不含個人資料。',
    ].join('\n'),
  };
}

/** The short code riders see, e.g. S-1A2B3C4D. */
export const supportCode = (id: string) => `S-${id.slice(0, 8).toUpperCase()}`;

/** What riders call each kind (#295). */
export const kindNames: Record<Kind, string> = {
  general: '一般問題',
  data_issue: '資料錯誤或侵權',
  complaint: '檢舉與申訴',
  privacy: '個資權利請求',
  account_deletion: '刪除帳號申請',
};

/** The closing line of a mail without a case link (#295). */
const replyLine =
  `有問題請直接回覆這封信（會寄到 ${supportAddress} 並登錄為客服案件），客服會在 5 個工作天內回覆。`;
/** The closing lines of a case mail (#295). */
const caseLines = (link: string | null) => [
  '要補充內容，請直接回覆這封信，或打開案件連結（30 天內有效）：',
  ...(link ? [link] : []),
  '回覆會接到同一個案件；附件不會收下，請把內容寫在信裡。',
];

/**
 * The receipt to the contact email of an account deletion or a privacy
 * request: nothing about any account (#285).
 */
export function receiptMail(id: string, kind: Kind = 'account_deletion') {
  return {
    subject: `【機車停車指南】已收到你的申請 ${supportCode(id)}`,
    text: [
      `已收到你的${kindNames[kind]}，編號 ${supportCode(id)}。`,
      '',
      '如果你填寫的登入 email 是本服務帳號的登入信箱，確認信會寄到那個信箱，請依信中說明確認。',
      '為了保護帳號，這封信和客服的任何回覆都不會告訴你是否找到帳號。',
      '客服會在 5 個工作天內處理。',
      '',
      replyLine.replace('有問題', '有問題（請附上申請編號）'),
      siteUrl,
    ].join('\n'),
  };
}

/** A general case's receipt: the case link and the Reply-To (#295). */
export function caseReceiptMail(id: string, kind: Kind, link: string | null) {
  return {
    subject: `【機車停車指南】已收到你的${kindNames[kind]} ${supportCode(id)}`,
    text: [
      `已收到你的${kindNames[kind]}，案件編號 ${supportCode(id)}。`,
      '客服會在 5 個工作天內回覆到這個信箱。',
      '',
      ...caseLines(link),
      '',
      siteUrl,
    ].join('\n'),
  };
}

/** An administrator's answer (#295): the text, then how to add to it. */
export function replyMail(id: string, body: string, link: string | null) {
  return {
    subject: `【機車停車指南】客服回覆 ${supportCode(id)}`,
    text: [
      body,
      '',
      '——',
      `案件編號 ${supportCode(id)}`,
      ...caseLines(link),
      '',
      siteUrl,
    ].join('\n'),
  };
}

/** The confirmation mail of a privacy request to the login email (#295). */
export function privacyConfirmMail(link: string) {
  return {
    subject: '【機車停車指南】請確認個資權利請求',
    text: [
      '我們收到一筆個資權利請求（查詢、更正或取得複本），請求的帳號以這個信箱登入。',
      '',
      '請在 24 小時內打開下面的連結。頁面會顯示請求內容；確認是你本人提出後，按「是我」，客服才會處理，資料也只會寄到這個信箱：',
      link,
      '',
      '連結只能使用一次，過期或用過即失效。如果不是你提出的，請在頁面上按「不是我申請的」，或直接忽略這封信。',
      '',
      replyLine,
      siteUrl,
    ].join('\n'),
  };
}

/** The confirmation mail to the login email (#285). */
export function confirmMail(link: string) {
  return {
    subject: '【機車停車指南】請確認刪除帳號的申請',
    text: [
      '我們收到一筆刪除帳號的申請，申請的帳號以這個信箱登入。',
      '',
      '請在 24 小時內打開下面的連結。頁面會顯示申請內容；確認是你本人申請後，按「是我，請申請刪除」，就會為這個帳號申請刪除：',
      link,
      '',
      '連結只能使用一次，過期或用過即失效。申請後有 7 天冷靜期，期間登入 App 選「取消刪除」就可以取消。',
      '',
      '如果不是你申請的，請在頁面上按「不是我申請的」，這筆申請就會作廢；或直接忽略這封信，帳號不會有任何變動。',
      '',
      replyLine,
      siteUrl,
    ].join('\n'),
  };
}

/** `2026/11/08 15:30` in Taiwan time. */
export function taiwanTime(iso: string): string {
  const t = new Date(new Date(iso).getTime() + 8 * 3600_000);
  const two = (n: number) => String(n).padStart(2, '0');
  return `${t.getUTCFullYear()}/${two(t.getUTCMonth() + 1)}/${
    two(t.getUTCDate())
  } ${two(t.getUTCHours())}:${two(t.getUTCMinutes())}`;
}

const appleSteps = [
  '',
  '這個帳號以 Apple 登入。因為無法在你登入時取得授權，我們沒有替你撤銷 Apple 的登入授權；',
  '如果要停止讓本服務使用你的 Apple ID，請到 Apple ID 設定的「使用 Apple 登入」自行移除本服務',
  '（iPhone：「設定 > 你的姓名 > 使用 Apple 登入」）。',
];

const cancelLines = (scheduledAt: string) => [
  `預計刪除時間：${taiwanTime(scheduledAt)}（台灣時間）`,
  '',
  '在這之前登入 App 選「取消刪除」，就可以取消。',
  '時間到了以後，帳號會被刪除，無法復原；你新增的停車點與回報會保留但不再顯示你的名稱。',
];

/** The notice once the owner's confirmation asked for the deletion (#285). */
export function deletionNoticeMail(
  scheduledAt: string,
  apple: boolean,
  cancelLink: string | null = null,
) {
  return {
    subject: '【機車停車指南】已為你的帳號申請刪除',
    text: [
      '你已透過確認信的連結，為以這個信箱登入的帳號申請刪除。',
      '',
      ...cancelLines(scheduledAt),
      '申請後 7 天內都可以取消。',
      ...(cancelLink
        ? [
          '',
          '登不進 App 也可以打開下面的連結取消（冷靜期內有效、只能使用一次）：',
          cancelLink,
        ]
        : []),
      ...(apple ? appleSteps : []),
      '',
      '如果不是你申請的，請立刻登入 App 取消，並直接回覆這封信告訴客服。',
      siteUrl,
    ].join('\n'),
  };
}

/**
 * To the login email of an account already in the cooling-off period, with
 * a one-time 取消刪除 link (#295) whether the App or the form asked for it.
 */
export function statusMail(
  scheduledAt: string,
  cancelLink: string | null = null,
) {
  return {
    subject: '【機車停車指南】你的帳號已在申請刪除中',
    text: [
      '我們收到一筆刪除帳號的申請，申請的帳號以這個信箱登入；這個帳號已經申請刪除，不需要再申請。',
      '',
      ...cancelLines(scheduledAt),
      ...(cancelLink
        ? [
          '',
          '登不進 App 也可以打開下面的連結取消（冷靜期內有效、只能使用一次）：',
          cancelLink,
        ]
        : []),
      '',
      replyLine,
      siteUrl,
    ].join('\n'),
  };
}

export function resendNotifier(
  config: ResendConfig | null,
  fetcher: typeof fetch = fetch,
): Notifier {
  if (!config) return silentNotifier;
  return {
    async notify({ id, adminUrl, replyId }: Notice) {
      await sendMail(
        config,
        { to: config.to, ...noticeMail(id, adminUrl, replyId !== undefined) },
        // A retry of the same notice is not sent twice (kept 24 hours).
        replyId ? `support-reply/${replyId}` : `support-request/${id}`,
        fetcher,
      );
      return true;
    },
  };
}
