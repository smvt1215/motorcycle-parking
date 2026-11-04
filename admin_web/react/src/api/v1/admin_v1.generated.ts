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
  kind: 'account_deletion';
  /** 聯絡用 email，已轉小寫；只寄固定回條（#285）。回覆時不要透露是否找到帳號 */
  contact_email: string;
  /** 申請者說明的帳號線索（登入方式、當時的 email 或名稱） */
  account_hint: string;
  message: string;
  /** open：已寄確認信，等登入信箱的主人確認；done：已確認並建立刪除申請（或客服結案）；rejected：客服結案；voided：申請者按「不是我申請的」，或重送後被取代；expired：確認連結過期；exception：系統例外，只記錄（見 exception）。open 以外都有 resolved_at */
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
  /** 申請者填的帳號登入 email，已轉小寫，只用來比對帳號；確認信與通知信只寄到這裡（#285）。#285 之前的申請為 null */
  login_email: string | null;
  /** 送出時登入 email 正好是一個帳號的（auth.users 或 auth.identities，不分大小寫，含 Apple 隱藏的電子郵件） */
  account_matched: boolean;
  /** 對到的帳號；沒對到或帳號已刪除時為 null */
  matched_user: string | null;
  /** ISO 8601 時間。登入信箱的主人在確認頁按「是我」的時間 */
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
};
export type SupportResolution = {
  id: string;
  status: 'done' | 'rejected';
};
export const {
  useAdminV1SetMinSupportedAppVersionMutation,
  useAdminV1SupportRequestsQuery,
  useAdminV1ResolveSupportRequestMutation,
} = injectedRtkApi;
