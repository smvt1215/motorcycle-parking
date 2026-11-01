import { apiV1Base as api } from './base';
const injectedRtkApi = api.injectEndpoints({
  endpoints: (build) => ({
    apiV1ClientConfig: build.query<ApiV1ClientConfigApiResponse, ApiV1ClientConfigApiArg>({
      query: () => ({ url: `/rpc/client_config`, method: 'POST' }),
    }),
  }),
  overrideExisting: false,
});
export { injectedRtkApi as apiV1 };
export type ApiV1ClientConfigApiResponse = /** status 200 版本資訊 */ ClientConfig;
export type ApiV1ClientConfigApiArg = void;
export type ClientConfig = {
  /** 低於這個版本的 App 要提示更新 */
  min_supported_app_version: string;
  /** data_versions 的 rules 版本 */
  rules_version: number;
  /** data_versions 的 spots 版本 */
  spots_version: number;
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
export const { useApiV1ClientConfigQuery } = injectedRtkApi;
