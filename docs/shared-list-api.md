# iKiwi 共享清單 API 說明

這份文件說明如何用程式讀寫 iKiwi 的共享清單，讓其他 app 也能接上同一個房間。
資料庫是 Supabase（PostgreSQL），完整的資料表與函式定義在 [`shared-list.sql`](shared-list.sql)。

> **重要：** 房間碼就是這個房間唯一的鑰匙。拿到房間碼的人可以讀取、新增、修改、刪除房間裡的全部資料。請只給信任的人，不要貼在公開的地方。

## 需要的三樣東西

| 項目 | 說明 | 誰給 |
|---|---|---|
| 專案網址 `<PROJECT_URL>` | 例如 `https://xxxx.supabase.co` | 專案擁有者 |
| 公開金鑰 `<PUBLISHABLE_KEY>` | `sb_publishable_` 開頭。設計上可以公開，只能呼叫下面的函式 | 專案擁有者 |
| 房間碼 `<ROOM>` | 32 個小寫英數字（0-9、a-f），至少 20 個字元 | 房間的人 |

**不要要求、也不要使用：** `secret` / `service_role` 金鑰、資料庫密碼。這些可以繞過所有權限，不是這個 API 需要的。

想要一個獨立的測試房間：自己隨機產生 32 個十六進位字元當房間碼即可，不用事先註冊，第一次寫入就會建立。

## 呼叫方式

所有函式都是同一種呼叫：

```
POST <PROJECT_URL>/rest/v1/rpc/<函式名稱>
apikey: <PUBLISHABLE_KEY>
Content-Type: application/json
```

資料表本身不能直接讀寫，只能透過下面的函式。

## 函式

### `ikiwi_pull` — 讀取房間

參數：

| 名稱 | 型別 | 說明 |
|---|---|---|
| `p_room` | text | 房間碼 |
| `p_since` | timestamptz | 只回傳這個時間之後有變動的項目。第一次用 `1970-01-01T00:00:00Z` |
| `p_member` | uuid（選填） | 成員 ID，傳了會更新這個成員的最後上線時間 |

回傳：項目陣列，依 `updated_at` 由舊到新排序。**已刪除（在垃圾桶裡）的項目也會回傳**，`deleted` 為 `true`，這樣才知道要把它從畫面拿掉。

每次讀取時，伺服器也會順便把在垃圾桶超過 30 天的項目永久刪除。

```bash
curl -X POST "<PROJECT_URL>/rest/v1/rpc/ikiwi_pull" \
  -H "apikey: <PUBLISHABLE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"p_room":"<ROOM>","p_since":"1970-01-01T00:00:00Z"}'
```

回傳的每個項目：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `id` | uuid | 項目 ID（用戶端自己產生） |
| `name` | text | 名稱（最長 200 字） |
| `lat`、`lng` | number | 緯度 -90~90、經度 -180~180。路線是第一個站點 |
| `category` | text | 分類，空字串表示未分類（最長 100 字） |
| `note` | text | 備註（最長 1000 字） |
| `deleted` | boolean | 是否在垃圾桶 |
| `updated_at` | timestamptz | 最後修改時間（伺服器時間） |
| `created_at` | timestamptz | 新增時間 |
| `deleted_at` | timestamptz 或 null | 丟進垃圾桶的時間 |
| `created_by` | text | 新增者的 emoji，舊資料為空字串 |
| `kind` | text | `place`（座標）或 `route`（路線） |
| `payload` | object 或 null | 路線的內容，座標為 null |
| `room` | text | 房間碼（回傳時會帶著，通常不需要用） |

時間格式像 `2026-11-21T03:04:05.123456+00:00`。

**增量讀取：** 記下上一次回傳最後一筆的 `updated_at`，下次當作 `p_since`。建議偶爾（例如每 10 分鐘或開啟畫面時）用 `1970-01-01T00:00:00Z` 完整讀取一次。完整讀取時，本機有、但伺服器沒有的項目，代表已被永久刪除，可以移除。

### `ikiwi_push` — 新增、修改、刪除

參數：

| 名稱 | 型別 | 說明 |
|---|---|---|
| `p_room` | text | 房間碼 |
| `p_items` | json 陣列 | 要寫入的項目，一次最多 200 筆 |

回傳：伺服器寫入時間（字串）。

每個項目：

| 欄位 | 必填 | 說明 |
|---|---|---|
| `id` | 是 | UUID。已存在就是修改，不存在就是新增 |
| `name`、`lat`、`lng` | 是 | 同上 |
| `category`、`note` | 否 | 預設空字串 |
| `deleted` | 否 | `true` 是丟進垃圾桶，`false` 是新增或還原 |
| `created_by` | 否 | 新增者 emoji（最長 16 字）。已經有值就不會被覆蓋 |
| `kind` | 否 | `place` 或 `route`。不傳就維持原本 |
| `payload` | 否 | 路線內容（見下方）。不傳就維持原本，最大約 10 萬字元 |
| `purge` | 否 | `true` 是永久刪除。**只有已在垃圾桶裡的項目才會被刪除** |

```bash
curl -X POST "<PROJECT_URL>/rest/v1/rpc/ikiwi_push" \
  -H "apikey: <PUBLISHABLE_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "p_room": "<ROOM>",
    "p_items": [{
      "id": "8f14e45f-ceea-467a-9575-6d7a1b3c1a10",
      "name": "公園入口",
      "lat": 25.033,
      "lng": 121.5654,
      "category": "",
      "note": "",
      "deleted": false
    }]
  }'
```

規則：
- `updated_at`、`created_at`、`deleted_at` 都由伺服器設定，不用也不能自己傳。
- 兩個人同時改同一筆，以最後送到伺服器的為準。
- 丟進垃圾桶：用同一個 `id`，傳 `"deleted": true`。還原：傳 `"deleted": false`。
- 永久刪除：傳 `"purge": true`，並且 `id` 對應的項目必須已經 `deleted`。

### 路線的 `payload`

`kind` 是 `route` 時，`payload` 是這樣的物件：

```json
{
  "stops": [[25.033, 121.5654], [25.04, 121.56]],
  "modeRaw": "walking",
  "speedKmh": 5,
  "shapeRaw": "oneWay",
  "followRoads": true,
  "hop": false,
  "dwellSeconds": 3
}
```

| 欄位 | 說明 |
|---|---|
| `stops` | 站點，每個是 `[緯度, 經度]` |
| `modeRaw` | `walking`（走路）、`cycling`（騎車）、`driving`（開車）、`detect`（偵測） |
| `speedKmh` | 速度，公里/小時 |
| `shapeRaw` | `oneWay`（單程）、`roundTrip`（來回）、`circuit`（繞圈） |
| `followRoads` | `true` 沿道路，`false` 直線 |
| `hop`、`dwellSeconds` | 選填。點對點飛模式，以及每站停留秒數 |

建議站點不要超過 400 個。

### `ikiwi_join` — 加入房間，取得 emoji

| 名稱 | 說明 |
|---|---|
| `p_room` | 房間碼 |
| `p_member` | 成員 ID。用戶端自己產生一個 UUID，並一直使用 |
| `p_avoid` | 選填。不想再抽到的 emoji（例如上次的） |

回傳：這個成員的 emoji（JSON 字串，例如 `"🦊"`）。
- 同一個 `p_member` 再呼叫，會拿回同一個 emoji。
- 新成員會從 66 個 emoji 中隨機抽一個，**同房間現有成員不會重複**。
- 超過 30 天沒有上線的成員，emoji 會被釋放。
- 房間滿了會回錯誤 `room full`。

### `ikiwi_leave` — 離開房間

參數：`p_room`、`p_member`。釋放這個成員的 emoji。

### `ikiwi_version` — 資料庫版本

無參數，回傳整數（目前是 `3`）。用來判斷資料庫是否支援路線等功能。

## 錯誤

| HTTP | 意思 |
|---|---|
| 400 | 參數不合法，例如房間碼太短（`bad room`）、一次超過 200 筆（`bad items`）、payload 太大 |
| 401 / 403 | 金鑰不正確 |
| 404 | 找不到函式（資料庫還沒執行最新的 SQL，或參數名稱寫錯） |
| 503 / 540 | Supabase 專案被暫停（免費版閒置 7 天會暫停），需要擁有者到網站喚醒 |

## 使用上的建議

- 不要太頻繁輪詢，每 20 秒一次已經足夠（iKiwi 本身也是這樣）。免費版有用量上限，所有人共用。
- 寫入時先寫本機，再送到伺服器；失敗時保留，下次再送。
- 顯示時，`deleted` 為 `true` 的項目不要顯示在主清單，可以另外做「垃圾桶」。
- 這個介面可能增加欄位，請忽略不認得的欄位。

## 範例：supabase-js

```js
import { createClient } from '@supabase/supabase-js'

const supabase = createClient('<PROJECT_URL>', '<PUBLISHABLE_KEY>')

const { data, error } = await supabase.rpc('ikiwi_pull', {
  p_room: '<ROOM>',
  p_since: '1970-01-01T00:00:00Z',
})
```
