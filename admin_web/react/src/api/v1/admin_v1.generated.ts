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
    adminV1RequestAccountDeletionFor: build.mutation<
      AdminV1RequestAccountDeletionForApiResponse,
      AdminV1RequestAccountDeletionForApiArg
    >({
      query: (queryArg) => ({
        url: `/rpc/request_account_deletion_for`,
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
    /** 只列這個狀態；null 列全部 */
    p_status?: ('open' | 'done' | 'rejected' | null) | ('open' | 'done' | 'rejected' | null);
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
export type AdminV1RequestAccountDeletionForApiResponse =
  /** status 200 刪除申請的狀態 */ AdminAccountDeletion;
export type AdminV1RequestAccountDeletionForApiArg = {
  body: {
    /** 要刪除的帳號 */
    p_user: string;
    /** 客服申請編號 */
    p_support_request: string;
    /** 如何確認身分 */
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
  /** 回覆用，已轉小寫 */
  contact_email: string;
  /** 申請者說明的帳號線索（登入方式、當時的 email 或名稱） */
  account_hint: string;
  message: string;
  status: 'open' | 'done' | 'rejected';
  /** ISO 8601 時間。送出時間 */
  created_at: string;
  /** ISO 8601 時間。通知信寄出時間；沒有寄信服務時為 null */
  notified_at: string | null;
  /** ISO 8601 時間。結案時間 */
  resolved_at: string | null;
  resolution_note: string;
  /** 已代為建立刪除申請 */
  deletion_requested: boolean;
};
export type SupportResolution = {
  id: string;
  status: 'done' | 'rejected';
};
export type AdminAccountDeletion = {
  status: 'none' | 'pending';
  /** ISO 8601 時間。申請時間 */
  requested_at: string | null;
  /** ISO 8601 時間。最早刪除時間（申請＋7 天） */
  scheduled_at: string | null;
  /** ISO 8601 時間。最近一次取消 */
  cancelled_at: string | null;
  cancelled_by_sign_in: boolean | null;
  support_request: string;
};
export const {
  useAdminV1SetMinSupportedAppVersionMutation,
  useAdminV1SupportRequestsQuery,
  useAdminV1ResolveSupportRequestMutation,
  useAdminV1RequestAccountDeletionForMutation,
} = injectedRtkApi;
