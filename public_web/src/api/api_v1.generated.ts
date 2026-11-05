import { apiV1Base as api } from './base';
const injectedRtkApi = api.injectEndpoints({
  endpoints: (build) => ({
    apiV1AccountDeletionStatus: build.query<
      ApiV1AccountDeletionStatusApiResponse,
      ApiV1AccountDeletionStatusApiArg
    >({
      query: () => ({ url: `/rpc/account_deletion_status`, method: 'POST' }),
    }),
    apiV1RequestAccountDeletion: build.mutation<
      ApiV1RequestAccountDeletionApiResponse,
      ApiV1RequestAccountDeletionApiArg
    >({
      query: (queryArg) => ({
        url: `/rpc/request_account_deletion`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    apiV1CancelAccountDeletion: build.mutation<
      ApiV1CancelAccountDeletionApiResponse,
      ApiV1CancelAccountDeletionApiArg
    >({
      query: () => ({ url: `/rpc/cancel_account_deletion`, method: 'POST' }),
    }),
  }),
  overrideExisting: false,
});
export { injectedRtkApi as apiV1 };
export type ApiV1AccountDeletionStatusApiResponse = /** status 200 刪除申請的狀態 */ AccountDeletionState;
export type ApiV1AccountDeletionStatusApiArg = void;
export type ApiV1RequestAccountDeletionApiResponse = /** status 200 刪除申請的狀態 */ AccountDeletionState;
export type ApiV1RequestAccountDeletionApiArg = {
  body: {
    /** 從哪裡申請：App 內（app）或 App 外的刪除網頁（web），只記在稽核 */
    p_source?: 'app' | 'web';
  };
};
export type ApiV1CancelAccountDeletionApiResponse = /** status 200 刪除申請的狀態 */ AccountDeletionState;
export type ApiV1CancelAccountDeletionApiArg = void;
export type AccountDeletionState = {
  /** none：沒有申請；pending：冷靜期中，到 scheduled_at 後刪除 */
  status: 'none' | 'pending';
  /** ISO 8601 時間。申請時間；none 時為 null */
  requested_at: string | null;
  /** ISO 8601 時間。最早刪除時間（申請＋7 天），實際在之後的每日排程（台灣 03:41）執行；none 時為 null */
  scheduled_at: string | null;
  /** 這個帳號能不能自助申請刪除；管理員為 false（要先由其他管理員移除權限）。App 在刪除說明頁就依此提示 */
  can_self_delete: boolean;
  /** 不能自助刪除的原因（錯誤碼）；可以時為 null */
  cannot_self_delete_reason:
    ('account.admin_cannot_self_delete' | null) | ('account.admin_cannot_self_delete' | null);
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
export const {
  useApiV1AccountDeletionStatusQuery,
  useApiV1RequestAccountDeletionMutation,
  useApiV1CancelAccountDeletionMutation,
} = injectedRtkApi;
