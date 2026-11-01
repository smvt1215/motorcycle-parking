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
export const { useAdminV1SetMinSupportedAppVersionMutation } = injectedRtkApi;
