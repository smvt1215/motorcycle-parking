import { apiV1Base as api } from './base';
const injectedRtkApi = api.injectEndpoints({
  endpoints: (build) => ({
    apiV1ClientConfig: build.query<ApiV1ClientConfigApiResponse, ApiV1ClientConfigApiArg>({
      query: () => ({ url: `/rpc/client_config`, method: 'POST' }),
    }),
    apiV1CityRules: build.query<ApiV1CityRulesApiResponse, ApiV1CityRulesApiArg>({
      query: () => ({ url: `/rpc/city_rules`, method: 'POST' }),
    }),
  }),
  overrideExisting: false,
});
export { injectedRtkApi as apiV1 };
export type ApiV1ClientConfigApiResponse = /** status 200 版本資訊 */ ClientConfig;
export type ApiV1ClientConfigApiArg = void;
export type ApiV1CityRulesApiResponse = /** status 200 規則 */ CityRules;
export type ApiV1CityRulesApiArg = void;
export type ClientConfig = {
  /** 低於這個版本的 App 一律整個擋下，必須更新才能繼續使用（使用者決定，#195 §7 第 7 題）。伺服器寧可不擋：沒有設定、格式不對或讀取失敗時回 0.1.0。App 離線或讀不到 client_config 時也不可以擋。只有 admin_v1.set_min_supported_app_version 能修改，每次修改都留稽核紀錄。 */
  min_supported_app_version: string;
  /** data_versions 的 rules 版本 */
  rules_version: number;
  /** data_versions 的 spots 版本 */
  spots_version: number;
  /** 官方即時車位仍在 Beta 的縣市（例如 臺北市），依名稱排序；App 依此顯示 Beta 標示，結束 Beta 不需發版。沒有就是空陣列 */
  availability_beta_cities: string[];
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
export type CityRule = {
  /** 縣市，或「全國」 */
  city: string;
  vehicle: 'scooter' | 'heavy';
  /** 可停的格位類型 */
  allowed_space_types: string[];
  /** 有條件可停的格位類型 */
  conditional_space_types: string[];
  /** 只在部分行政區開放的格位類型：格位類型 → 行政區清單 */
  district_space_types: object;
  /** 規則適用的行政區；空陣列表示全區 */
  districts: string[];
  /** 有條件可停時的限制種類 */
  restriction:
    ('pilot_area' | 'signage' | 'unverified' | null) | ('pilot_area' | 'signage' | 'unverified' | null);
  fee_note: string;
  exceptions: string;
  can_use_two_spaces: boolean;
  effective_date: string;
  /** 從這天起（臺灣日期）規則過期；null 表示沒有期限 */
  expires_on: string | null;
  source_url: string;
  /** 這條規則的版本 */
  version: number;
};
export type CityRules = {
  /** 整份規則的版本，與 client_config 的 rules_version 相同 */
  rules_version: number;
  /** 依 city、vehicle 排序；沒有規則就是空陣列 */
  rules: CityRule[];
};
export const { useApiV1ClientConfigQuery, useApiV1CityRulesQuery } = injectedRtkApi;
