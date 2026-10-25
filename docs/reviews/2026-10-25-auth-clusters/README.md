# 登入回跳與群聚門檻截圖自檢

390 × 844 邏輯像素，Android／iOS 各含深淺色，共 20 張原始截圖，整理成四張檢查圖：

- [Android 淺色](android-light.png)
- [Android 深色](android-dark.png)
- [iOS 淺色](iOS-light.png)
- [iOS 深色](iOS-dark.png)

每張依序顯示：原表單的登入按鈕、登入後保留草稿與下方提示、修改建議立即啟用送出、四個鄰近點保留個別標記、五個鄰近點顯示群聚。登入前畫面捲至登入按鈕；登入後畫面捲回表單上方以檢查標題與草稿。提示位於所有面板上方，出現三秒且不攔截操作。

使用 Flutter widget 測試與實際 App 元件。登入經 Supabase callback parser 與 AppStore auth listener，HTTP 使用測試回應；不代表已完成真實 Google／Apple 帳號的實機登入。地圖使用離線預覽，因此沒有街道圖磚；Google 地圖的四點／五點門檻、群聚 bitmap 大小及選取行為另以平台介面測試驗證。iOS 圖為 Flutter 測試平台樣式；原生系統瀏覽器與 iOS 26 原生玻璃元件仍需裝置確認。測試停用陰影模糊，圖中的陰影邊界較實機明顯。
