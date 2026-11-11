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
    apiV1MyAccountStatus: build.query<ApiV1MyAccountStatusApiResponse, ApiV1MyAccountStatusApiArg>({
      query: () => ({ url: `/rpc/my_account_status`, method: 'POST' }),
    }),
    apiV1SpotsByIds: build.query<ApiV1SpotsByIdsApiResponse, ApiV1SpotsByIdsApiArg>({
      query: (queryArg) => ({
        url: `/rpc/spots_by_ids`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    apiV1SpotSightings: build.query<ApiV1SpotSightingsApiResponse, ApiV1SpotSightingsApiArg>({
      query: (queryArg) => ({
        url: `/rpc/spot_sightings`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    apiV1HiddenRidersList: build.query<ApiV1HiddenRidersListApiResponse, ApiV1HiddenRidersListApiArg>({
      query: () => ({ url: `/rpc/hidden_riders_list`, method: 'POST' }),
    }),
    apiV1HiddenRidersMerge: build.mutation<ApiV1HiddenRidersMergeApiResponse, ApiV1HiddenRidersMergeApiArg>({
      query: (queryArg) => ({
        url: `/rpc/hidden_riders_merge`,
        method: 'POST',
        body: queryArg.body,
      }),
    }),
    apiV1HiddenRidersRemove: build.mutation<
      ApiV1HiddenRidersRemoveApiResponse,
      ApiV1HiddenRidersRemoveApiArg
    >({
      query: (queryArg) => ({
        url: `/rpc/hidden_riders_remove`,
        method: 'POST',
        body: queryArg.body,
      }),
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
export type ApiV1MyAccountStatusApiResponse = /** status 200 停權狀態 */ AccountStatus;
export type ApiV1MyAccountStatusApiArg = void;
export type ApiV1SpotsByIdsApiResponse = /** status 200 依 id 讀多個停車點（收藏頁） */ SpotsByIds;
export type ApiV1SpotsByIdsApiArg = {
  body: {
    /** 停車點 id */
    ids: string[];
  };
};
export type ApiV1SpotSightingsApiResponse =
  /** status 200 依 id 讀騎士回報的彙整（地圖、詳情） */ SpotSightings;
export type ApiV1SpotSightingsApiArg = {
  body: {
    /** 停車點 id */
    p_spot_ids: string[];
    /** 只看最近幾分鐘：地圖 15，詳情 30 */
    p_window_minutes?: 15 | 30;
  };
};
export type ApiV1HiddenRidersListApiResponse = /** status 200 自己隱藏的車友 */ HiddenRiders;
export type ApiV1HiddenRidersListApiArg = void;
export type ApiV1HiddenRidersMergeApiResponse = /** status 200 把隱藏的車友併入帳號 */ HiddenRiders;
export type ApiV1HiddenRidersMergeApiArg = {
  body: {
    items: HiddenRider[];
  };
};
export type ApiV1HiddenRidersRemoveApiResponse = /** status 200 解除隱藏一位車友 */ HiddenRiders;
export type ApiV1HiddenRidersRemoveApiArg = {
  body: {
    handle: string;
  };
};
export type ClientConfig = {
  /** 低於這個版本的 App 一律整個擋下，必須更新才能繼續使用（使用者決定，#195 §7 第 7 題）。伺服器寧可不擋：沒有設定、格式不對或讀取失敗時回 0.1.0。App 離線或讀不到 client_config 時也不可以擋。只有 admin_v1.set_min_supported_app_version 能修改，每次修改都留稽核紀錄。 */
  min_supported_app_version: string;
  /** data_versions 的 rules 版本 */
  rules_version: number;
  /** data_versions 的 spots 版本 */
  spots_version: number;
  /** 官方即時車位仍在 Beta 的縣市（例如 臺北市），依 Unicode 碼位排序；App 依此顯示 Beta 標示，結束 Beta 不需發版。沒有就是空陣列 */
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
  /** 投稿者的公開代號（#280），只用來在本機「隱藏這位車友」。帳號公開過名稱（車友新增的點上出現過非空、不含 @ 的名稱）就一直回傳，直到刪除帳號；之後改名、名稱空白或像 email、被管理員清除照樣回傳。從沒公開過名稱、管理員新增或匯入、已匿名化與官方點為 null。同一帳號的點代號相同，不輪替；不是使用者 ID。 */
  contributor_handle?: string | null;
  /** 已登入且這個點是自己新增的（#280）；未登入、官方點一律 false。依呼叫時的登入身分計算。 */
  is_own?: boolean;
  /** 因內容不當檢舉而暫時遮蔽的部分（#280）：rider_name（contributor_name 回空字串，代號照回）、spot_name（name 回「名稱審核中」）、text（note、entrance_note、parking_guide、special_rules 回空字串）。投稿者本人（is_own）看到原文，仍回這個欄位。官方點沒有這個欄位。 */
  content_held?: ('rider_name' | 'spot_name' | 'text')[] | null;
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
export type AccountStatus = {
  /** 是否停權中；停權中 App 的寫入一律回 account.suspended */
  suspended: boolean;
  /** ISO 8601 時間。停權到期時間；無限期或沒有停權時為 null */
  suspended_until: string | null;
};
export type SpotsByIds = {
  /** 看得到的點；官方點在前、社群點在後，各依 id 排序 */
  spots: Spot[];
};
export type SpotSighting = {
  /** 停車點 id */
  spot_id: string;
  /** 分區 id；不是分區的回報為 null */
  zone_id: string | null;
  /** 路段 id；不是路段的回報為 null */
  segment_id: string | null;
  /** 車種 */
  vehicle: 'scooter' | 'heavy';
  /** 加權中位數：0 很多空位、1 還有一些、2 快滿了、3 已停滿。說法不一時畫兩端用 low、high，不用這個值 */
  level: number;
  /** 列入彙整的車友人數：每人、每裝置各算最新一筆，不含停權與可信度不足者 */
  count: number;
  /** 回報中最小的 level（較空的一端） */
  low: number;
  /** 回報中最大的 level（較滿的一端） */
  high: number;
  /** 說 low 那一級的車友人數 */
  low_riders: number;
  /** 說 high 那一級的車友人數 */
  high_riders: number;
  /** ISO 8601 時間。列入彙整的最新一筆回報 */
  latest_at: string;
  /** 說法不一：中位數前後一級內的權重未達 70% */
  conflicting: boolean;
};
export type SpotClosure = {
  /** 停車點 id */
  spot_id: string;
  /** 分區 id；不是分區的列為 null */
  zone_id: string | null;
  /** 路段 id；不是路段的列為 null */
  segment_id: string | null;
  /** 回報關閉的獨立車友人數（帳號與裝置取較小者），不含停權與可信度不足者；有 2 個以上分區或路段的點，整點（全區）與各區分開計數，分區、路段的列不算全區回報（#408）；整點在所有分區或路段都確認時算全部回報 */
  riders: number;
  /** 分區、路段與沒有多個區段的點：回報人數達 2；有 2 個以上分區或路段的點的整點列：回報全區達 3 位，或所有區段都確認（#408）。true 才影響能不能停，false 只顯示有車友回報 */
  confirmed: boolean;
  /** ISO 8601 時間。列入的最新一筆回報 */
  latest_at: string;
  /** 整點列才可能是 true：沒有人直接回報整點，由所有分區或路段都確認而來 */
  derived: boolean;
};
export type SpotSightings = {
  /** 依 spot_id、zone_id、segment_id、vehicle 排序 */
  sightings: SpotSighting[];
  /** 依 spot_id、zone_id、segment_id 排序；同一個分區、路段或整點只有一列 */
  closures: SpotClosure[];
};
export type HiddenRider = {
  /** contributor_handle */
  handle: string;
  /** 隱藏當下看到的車友名稱；沒有名稱時空字串 */
  name_at_hide?: string;
  /** 隱藏時所在的點位名稱 */
  spot_name_at_hide?: string;
  /** ISO 8601 時間；2026-01-01T00:00:00Z 起，不可晚於現在 5 分鐘以上 */
  hidden_at: string;
};
export type HiddenRiders = {
  /** 依 hidden_at 新到舊 */
  items: HiddenRider[];
  /** 每帳號上限（500） */
  limit: number;
};
export const {
  useApiV1ClientConfigQuery,
  useApiV1CityRulesQuery,
  useApiV1SpotsInViewportQuery,
  useApiV1DataVersionsQuery,
  useApiV1AccountDeletionStatusQuery,
  useApiV1RequestAccountDeletionMutation,
  useApiV1CancelAccountDeletionMutation,
  useApiV1MyAccountStatusQuery,
  useApiV1SpotsByIdsQuery,
  useApiV1SpotSightingsQuery,
  useApiV1HiddenRidersListQuery,
  useApiV1HiddenRidersMergeMutation,
  useApiV1HiddenRidersRemoveMutation,
} = injectedRtkApi;
