import { adminV1Base as api } from './base';
const injectedRtkApi = api.injectEndpoints({
  endpoints: (build) => ({
    adminV1SetMinSupportedAppVersion: build.mutation<
      AdminV1SetMinSupportedAppVersionApiResponse,
      AdminV1SetMinSupportedAppVersionApiArg
    >({
      query: (queryArg) => ({
        url: `/rpc/set_min_supported_app_version`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    adminV1SupportRequests: build.query<AdminV1SupportRequestsApiResponse, AdminV1SupportRequestsApiArg>({
      query: (queryArg) => ({
        url: `/rpc/support_requests`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    adminV1ResolveSupportRequest: build.mutation<
      AdminV1ResolveSupportRequestApiResponse,
      AdminV1ResolveSupportRequestApiArg
    >({
      query: (queryArg) => ({
        url: `/rpc/resolve_support_request`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    adminV1SupportRequest: build.query<AdminV1SupportRequestApiResponse, AdminV1SupportRequestApiArg>({
      query: (queryArg) => ({
        url: `/rpc/support_request`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    adminV1ReplySupportRequest: build.mutation<
      AdminV1ReplySupportRequestApiResponse,
      AdminV1ReplySupportRequestApiArg
    >({
      query: (queryArg) => ({
        url: `/rpc/reply_support_request`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
  }),
  overrideExisting: false,
});
export { injectedRtkApi as adminV1 };
export type AdminV1SetMinSupportedAppVersionApiResponse = /** status 200 目前生效的最低版本 */ MinAppVersion;
export type AdminV1SetMinSupportedAppVersionApiArg = {
  body: {
    /** 新的最低版本 x.y.z */
    p_version: string;
    /** 原因；CD 帶上 run 的網址 */
    p_reason: string;
  };
};
export type AdminV1SupportRequestsApiResponse = /** status 200 申請 */ SupportRequest[];
export type AdminV1SupportRequestsApiArg = {
  body: {
    /** 只列這個狀態；all 列全部 */
    p_status?: 'open' | 'done' | 'rejected' | 'voided' | 'expired' | 'exception' | 'all';
    /** 只列這個類型；all 列全部 */
    p_kind?: 'general' | 'data_issue' | 'complaint' | 'privacy' | 'account_deletion' | 'all';
    /** true 只列等客服回覆的、false 只列不等的；null 不篩 */
    p_awaiting_admin?: boolean | null;
    p_limit?: number;
  };
};
export type AdminV1ResolveSupportRequestApiResponse = /** status 200 結案結果 */ SupportResolution;
export type AdminV1ResolveSupportRequestApiArg = {
  body: {
    p_id: string;
    p_status: 'done' | 'rejected';
    p_note?: string;
  };
};
export type AdminV1SupportRequestApiResponse = /** status 200 案件詳情 */ SupportRequestDetail;
export type AdminV1SupportRequestApiArg = {
  body: {
    p_id: string;
  };
};
export type AdminV1ReplySupportRequestApiResponse =
  /** status 200 這則回覆（delivery_status queued） */ SupportMessage;
export type AdminV1ReplySupportRequestApiArg = {
  body: {
    p_id: string;
    /** 回覆內文（純文字） */
    p_body: string;
  };
};
export type MinAppVersion = {
  /** 目前生效的最低版本 */
  min_supported_app_version: string;
  /** 這次呼叫是否改了值 */
  changed: boolean;
};
export type ApiError = {
  /** SQLSTATE；API 自訂錯誤為 PTxyz，HTTP 狀態即 xyz */
  code: string;
  /** 穩定錯誤碼，例如 auth.aal2_required；用戶端依此顯示文案 */
  message: string;
  /** JSON 字串，帶欄位等細節 */
  details?: string | null;
  hint?: string | null;
};
export type SupportRequest = {
  id: string;
  /** general 一般問題、data_issue 資料錯誤或侵權、complaint 檢舉與申訴、privacy 個資權利請求、account_deletion 刪除帳號（#285） */
  kind: 'general' | 'data_issue' | 'complaint' | 'privacy' | 'account_deletion';
  /** 聯絡用 email，已轉小寫。一般案件的回覆寄到這裡；刪除帳號與個資權利請求只寄固定回條（#285）。回覆時不要透露是否找到帳號 */
  contact_email: string;
  /** 申請者說明的帳號線索（登入方式、當時的 email 或名稱） */
  account_hint: string;
  message: string;
  /** open：處理中（刪除帳號與個資權利請求未確認時是等登入信箱的主人確認）；done／rejected：客服結案（30 天內使用者補充或回信會重新開啟）；done 也是刪除帳號已確認並建立申請；voided：申請者按「不是我申請的」，或重送後被取代；expired：確認連結過期；exception：系統例外，只記錄（見 exception）。open 以外都有 resolved_at */
  status: 'open' | 'done' | 'rejected' | 'voided' | 'expired' | 'exception';
  /** ISO 8601 時間。送出時間 */
  created_at: string;
  /** ISO 8601 時間。通知信寄出時間；沒有寄信服務時為 null */
  notified_at: string | null;
  /** ISO 8601 時間。結束時間（系統判定或客服結案）；滿 180 天後刪除 */
  resolved_at: string | null;
  resolution_note: string;
  /** 已建立刪除申請 */
  deletion_requested: boolean;
  /** 申請者填的帳號登入 email（刪除帳號與個資權利請求），已轉小寫；確認信、通知信與個資權利請求的回覆只寄到這裡（#285、#295）。其他類型為 null */
  login_email: string | null;
  /** 送出時登入 email 正好是一個帳號的（auth.users 或 auth.identities，不分大小寫，含 Apple 隱藏的電子郵件） */
  account_matched: boolean;
  /** 對到的帳號；沒對到或帳號已刪除時為 null */
  matched_user: string | null;
  /** ISO 8601 時間。登入信箱的主人在確認頁按「是我」的時間；個資權利請求要有它才能回覆 */
  email_confirmed_at: string | null;
  /** 系統例外的原因（status 為 exception 時）：no_account 沒對到帳號、admin_account 管理員帳號、deletion_pending 已在冷靜期（已寄狀態信到登入 email）、deletion_in_progress 正在刪除、account_deleted 已刪除。不建立刪除申請 */
  exception:
    | (
        | 'no_account'
        | 'admin_account'
        | 'deletion_pending'
        | 'deletion_in_progress'
        | 'account_deleted'
        | null
      )
    | (
        | 'no_account'
        | 'admin_account'
        | 'deletion_pending'
        | 'deletion_in_progress'
        | 'account_deleted'
        | null
      );
  /** ISO 8601 時間。建立刪除申請後寄到登入 email 的通知信寄出時間 */
  deletion_notified_at: string | null;
  /** ISO 8601 時間。以通知信的「取消刪除」連結取消的時間（#285） */
  cancelled_at: string | null;
  /** 重送時取代這筆的申請（status 為 voided） */
  superseded_by: string | null;
  /** web 客服表單、email 寄到 support@ 的信 */
  source: 'web' | 'email';
  /** 主旨（email 來源為信件主旨；表單可為空字串） */
  subject: string;
  /** 個資權利請求的項目：access 查詢、correction 更正、copy 複本；其他類型為 null */
  privacy_right: ('access' | 'correction' | 'copy' | null) | ('access' | 'correction' | 'copy' | null);
  /** ISO 8601 時間。回覆期限：送出（或重新開啟）後 5 個工作天結束（台灣時間；依 public.holidays，補班日算工作日） */
  due_at: string;
  /** 客服回覆會寄到的地址；不能回覆時 null（刪除帳號、個資權利請求未確認） */
  reply_to: string | null;
  /** 現在可以回覆：open 且 reply_to 不是 null */
  can_reply: boolean;
  /** 往來則數（不含原始內容） */
  message_count: number;
  /** ISO 8601 時間。最後一則往來的時間 */
  last_message_at: string | null;
  /** 等客服回覆：可以回覆，且還沒有往來或最後一則是使用者的 */
  awaiting_admin: boolean;
  /** 原始信件或任一封回信的 SPF／DKIM 未通過 */
  suspicious: boolean;
  /** ISO 8601 時間。最近一次因使用者補充或回信重新開啟的時間 */
  reopened_at: string | null;
  /** 結案超過 30 天後收到回信而開的新案件：指向舊案 */
  related_to: string | null;
};
export type SupportResolution = {
  id: string;
  status: 'done' | 'rejected';
};
export type SupportMessage = {
  id: string;
  /** in 使用者、out 客服回覆 */
  direction: 'in' | 'out';
  /** web 表單原始內容、email 信件（原始或回信）、case_link 案件連結的補充、admin 管理站回覆 */
  channel: 'web' | 'email' | 'case_link' | 'admin';
  body: string;
  /** ISO 8601 時間 */
  created_at: string;
  /** 回覆的管理員（out） */
  author: string | null;
  /** 信件的寄件人（channel email） */
  from_email: string | null;
  /** SPF 或 DKIM 未通過 */
  suspicious: boolean;
  /** Authentication-Results 的 SPF 結果（channel email） */
  spf:
    | ('pass' | 'fail' | 'softfail' | 'neutral' | 'none' | 'temperror' | 'permerror' | 'policy' | null)
    | ('pass' | 'fail' | 'softfail' | 'neutral' | 'none' | 'temperror' | 'permerror' | 'policy' | null);
  /** Authentication-Results 的 DKIM 結果（channel email） */
  dkim:
    | ('pass' | 'fail' | 'softfail' | 'neutral' | 'none' | 'temperror' | 'permerror' | 'policy' | null)
    | ('pass' | 'fail' | 'softfail' | 'neutral' | 'none' | 'temperror' | 'permerror' | 'policy' | null);
  /** 附件檔名；內容不收 */
  attachments: string[];
  /** 收件人（out） */
  to_email: string | null;
  /** 寄送狀態（out）：queued 待寄、sending 寄送中、sent 已寄出、failed 失敗（attempts 未滿 5 次會自動重試） */
  delivery_status:
    ('queued' | 'sending' | 'sent' | 'failed' | null) | ('queued' | 'sending' | 'sent' | 'failed' | null);
  /** 寄送次數（out） */
  attempts: number;
  /** ISO 8601 時間。寄出時間（out） */
  sent_at: string | null;
  /** 最後一次寄送失敗的原因（out） */
  send_error: string | null;
};
export type SupportRequestDetail = {
  request: SupportRequest;
  /** 舊到新；第一則是原始內容 */
  messages: SupportMessage[];
};
export const {
  useAdminV1SetMinSupportedAppVersionMutation,
  useAdminV1SupportRequestsQuery,
  useAdminV1ResolveSupportRequestMutation,
  useAdminV1SupportRequestQuery,
  useAdminV1ReplySupportRequestMutation,
} = injectedRtkApi;
