# PDD iOS 原生插件工作稿 v0.4

此版本的目標是讓專案更容易進入**可驗證的建置與測試流程**。它仍是待編譯的 Theos/Logos 原始碼，不是已經通過真機驗證的完整復刻成品。

## v0.4 相對 v0.3 的修正

- ZIP 建立與 TXT 讀取移至 utility background queue，避免大量檔案時阻塞主執行緒。
- 匯出 ZIP 改用數量 + UUID 命名，避免兩次同數量匯出互相覆蓋暫存檔。
- 分享面板與訊息提示在找不到有效 window/root view controller 時安全退出。
- 浮動按鈕的拖曳／長按手勢設定 `cancelsTouchesInView = NO`，降低手勢互相取消觸控的機會；仍需真機確認點擊、拖曳、長按的實際互動。
- 新增 `validate_source.py` 可攜式靜態檢查。
- 新增 `preflight.sh`，在已安裝 Theos 與 iOS SDK 的建置環境執行 `make clean package`。
- 修正套件資料夾與 ZIP 版本命名一致為 v0.4。

## 本版本具備

- 目標 bundle filter：`com.xunmeng.pinduoduo`。
- 懸浮按鈕、拖曳、ON/OFF 狀態持久化。
- `NSJSONSerialization JSONObjectWithData:options:error:` 的 Logos hook：先呼叫原始解析器，成功後檢查解析物件形狀。
- 根字典需包含 `goods` 字典、`sku` 陣列、`price` 字典，並要求 `goods.goods_id` 可安全用作檔名。
- 將本次呼叫的 `NSData` 複製後，序列化寫入 `Documents/PDDGoodsData/<goods_id>.txt`。
- 長按浮動按鈕可把 TXT 打包成 ZIP 並開啟 iOS 分享面板。

## 本版本仍未完成

- 沒有在此執行環境成功編譯 `.deb`：目前容器未配置 Theos/iOS SDK。
- 沒有真機注入測試，不能宣稱能安裝、能啟動或能捕獲全部商品頁資料。
- hook 只看到經過 `NSJSONSerialization` 這個入口的內容；其他解析器、壓縮／加密／非 JSON 資料路徑不會被此 hook 自動捕獲。
- 結構條件只是依已觀察到的資料形狀制定，需用你自己的真實 TXT/JSON 樣本對照驗證。
- 同一商品 ID 的新內容會覆蓋舊 TXT。
- 未復刻原版授權／卡密、反追蹤欄位修改、TLS challenge 或任何授權繞過。

## 建置及驗證

### 1. 靜態檢查（任何有 Python 3 的系統）

```sh
python3 validate_source.py
```

此檢查只確認源碼中必要結構存在，不等同於 Objective-C 編譯或真機測試。

### 2. Theos 建置（macOS/Linux，需先自行安裝 Theos 與相容 iOS SDK）

```sh
./preflight.sh
```

若建置失敗，請完整保留第一個 compiler error 及前後約 30 行輸出；這是修正工具鏈或原始碼所需的最小診斷資料。

### 3. 真機驗證清單

1. 確認安裝包的架構、rootless/rootful 方案與測試設備環境相符。
2. 安裝後確認拼多多能正常啟動，懸浮按鈕只出現一次。
3. 測試按鈕點擊、拖曳、長按；ON/OFF 後重啟 App，確認狀態是否保留。
4. 進入一個商品頁，檢查 `Documents/PDDGoodsData` 是否產生 `<goods_id>.txt`。
5. 比對 TXT 原始位元組是否為預期 JSON，並檢查檔案大小、ID、重複商品覆蓋行為。
6. 匯出 ZIP，使用 iOS 檔案或桌面解壓工具確認檔案數、名稱與內容。
7. 至少測試多個不同商品頁、返回列表、重新進入商品頁，以及快速切換頁面。

## 資料與隱私

商品 JSON 可能包含商品資訊、分享連結或其他 App 資料。只在你有權測試的裝置和資料上使用；不要分享未檢查的原始 TXT。日誌不輸出整份 JSON，但會輸出商品 ID 與位元組數。
