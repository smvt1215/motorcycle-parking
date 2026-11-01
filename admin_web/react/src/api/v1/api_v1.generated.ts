import { apiV1Base as api } from './base';
const injectedRtkApi = api.injectEndpoints({
  endpoints: (build) => ({
    apiV1ClientConfig: build.query<ApiV1ClientConfigApiResponse, ApiV1ClientConfigApiArg>({
      query: () => ({ url: `/rpc/client_config`, method: 'POST' }),
    }),
    apiV1CityRules: build.query<ApiV1CityRulesApiResponse, ApiV1CityRulesApiArg>({
      query: () => ({ url: `/rpc/city_rules`, method: 'POST' }),
    }),
    apiV1SpotsInViewport: build.query<ApiV1SpotsInViewportApiResponse, ApiV1SpotsInViewportApiArg>({
      query: (queryArg) => ({
        url: `/rpc/spots_in_viewport`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    apiV1DataVersions: build.query<ApiV1DataVersionsApiResponse, ApiV1DataVersionsApiArg>({
      query: () => ({ url: `/rpc/data_versions`, method: 'POST' }),
    }),
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
export type ApiV1ClientConfigApiResponse = /** status 200 版本資訊 */ ClientConfig;
export type ApiV1ClientConfigApiArg = void;
export type ApiV1CityRulesApiResponse = /** status 200 規則 */ CityRules;
export type ApiV1CityRulesApiArg = void;
export type ApiV1SpotsInViewportApiResponse = /** status 200 範圍內的點 */ SpotsInViewport;
export type ApiV1SpotsInViewportApiArg = {
  body: {
    /** WGS84 度 */
    south: number;
    /** WGS84 度 */
    west: number;
    /** WGS84 度 */
    north: number;
    /** WGS84 度 */
    east: number;
  };
};
export type ApiV1DataVersionsApiResponse = /** status 200 資料集 → 版本 */ DataVersions;
export type ApiV1DataVersionsApiArg = void;
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
export type Spot = {
  /** 官方點為 official: 加上 uuid */
  id: string;
  /** official、community 或其他資料來源 */
  source: string;
  source_name?: string | null;
  source_url?: string | null;
  license_note?: string | null;
  name: string;
  lat: number;
  lng: number;
  city?: string | null;
  district?: string | null;
  space_type?: string | null;
  fee_note?: string | null;
  note?: string | null;
  scooter_total?: number | null;
  available?: number | null;
  scooter_allowed?: boolean | null;
  heavy_allowed?: boolean | null;
  scooter_not_stated?: boolean | null;
  heavy_not_stated?: boolean | null;
  status?: string | null;
  /** ISO 8601 時間 */
  updated_at?: string | null;
  /** ISO 8601 時間 */
  last_confirmed_at?: string | null;
  /** ISO 8601 時間 */
  created_at?: string | null;
  /** ISO 8601 時間 */
  scooter_verified_at?: string | null;
  /** ISO 8601 時間 */
  heavy_verified_at?: string | null;
  facility_type?: string | null;
  facility_types?: string[] | null;
  parking_access?: string | null;
  address?: string | null;
  road_segment?: string | null;
  entrance_note?: string | null;
  parking_guide?: string | null;
  special_rules?: string | null;
  /** 照片網址清單 */
  photo_urls?: any;
  /** 分區清單；形狀見 supabase/functions/_shared/parking_contract.json 的 zone */
  parking_zones?: any;
  /** 費率；形狀見 supabase/functions/_shared/parking_contract.json 的 fee */
  fee?: any;
  /** 路邊格位的條件；形狀見 supabase/functions/_shared/parking_contract.json 的 condition */
  condition?: any;
  /** 路段清單；形狀見 supabase/functions/_shared/parking_contract.json 的 segment */
  parking_segments?: any;
  zones_complete?: boolean | null;
  /** 暫停使用的資訊 */
  closure?: any;
  closure_state?: string | null;
  contributor_name?: string | null;
  contributor_role?: string | null;
};
export type SpotsInViewport = {
  /** 官方點在前、社群點在後，各依 id 排序 */
  spots: Spot[];
  /** 任一層超過 500 筆，請縮小範圍 */
  truncated: boolean;
  /** 官方點這次沒有讀到（暫時無法讀取） */
  official_unavailable: boolean;
};
export type DataVersions = {
  rules: number;
  spots: number;
  [key: string]: number;
};
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
export const {
  useApiV1ClientConfigQuery,
  useApiV1CityRulesQuery,
  useApiV1SpotsInViewportQuery,
  useApiV1DataVersionsQuery,
  useApiV1AccountDeletionStatusQuery,
  useApiV1RequestAccountDeletionMutation,
  useApiV1CancelAccountDeletionMutation,
} = injectedRtkApi;
