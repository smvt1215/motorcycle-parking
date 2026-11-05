/// 表單共用元件（FormHeader、SubmitBar、AdaptiveTimeField、AdaptiveStepper）
/// 內建的文字。
library;

/// FormHeader 的「取消」（iOS 文字鈕；Android 是 close 圖示的朗讀）。
const formCancel = '取消';

/// Android close 圖示鈕的朗讀與 tooltip。
const formClose = '關閉';

/// FormHeader 的「返回」（iOS chevron 旁的文字；Android arrow_back 的朗讀）。
const formBack = '返回';

/// SubmitBar 送出中的按鈕字（沿用回報表單的寫法）。
const formSending = '送出中…';

/// 時間欄還沒有值時顯示的佔位字。
const timePlaceholder = '--:--';

/// 時間欄還沒有值時的朗讀值。
const timeUnset = '未設定';

/// 時間選擇器的按鈕與欄位標籤。
const timePickerConfirm = '確定';
const timePickerCancel = '取消';
const timePickerHour = '時';
const timePickerMinute = '分';
const timePickerInvalid = '請輸入 00:00–23:59 之間的時間';

/// AdaptiveStepper 減少／增加鈕的朗讀，例如「每次限停減少」。
String stepperDecrease(String label) => '$label減少';
String stepperIncrease(String label) => '$label增加';
