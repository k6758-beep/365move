# 厝邊平安鈴 v2：部署教學（GitHub Pages ＋ Supabase）

整個系統由兩半組成：**前端**放在 GitHub Pages（網頁本身），**後端**放在 Supabase（資料庫、帳號、排程、推播）。照下面的順序做一次，大約 60～90 分鐘。

## 檔案清單

| 檔案 | 放哪裡 | 用途 |
|---|---|---|
| `peace.html` | GitHub | 長輩端，網址 `peace.html#id=7F82K3QX` |
| `care.html` | GitHub | 志工／里長／社工的「今日關懷工作台」 |
| `config.js` | GitHub | **唯一需要修改的設定檔**（Supabase 網址與公開金鑰） |
| `sw.js`、`care.webmanifest`、`icon-192.png`、`icon-512.png` | GitHub | 推播與「加入主畫面」 |
| `vapid.html` | 自己電腦開啟即可（也可放 GitHub） | 產生推播金鑰 |
| `supabase/schema.sql` | 貼到 Supabase | 資料表、權限、自動升級規則 |
| `supabase/functions/send-push/index.ts` | 貼到 Supabase | 推播發送程式 |

建議在 `365move` repo 裡建一個新資料夾 `peacebell/`，把前端檔案放進去。舊的 `peace.html` 不用動，兩版可以並存。完成後網址會是：

- 工作台：`https://k6758-beep.github.io/365move/peacebell/care.html`
- 長輩端：`https://k6758-beep.github.io/365move/peacebell/peace.html#id=XXXXXXXX`

---

## 步驟 1　建立 Supabase 專案

1. 到 supabase.com → **Start your project** → 用 GitHub 帳號登入。
2. **New project**：
   - Name：`peacebell`
   - Database Password：按 Generate，**抄下來存好**（之後很少用到，但遺失很麻煩）
   - Region：選 **Northeast Asia (Tokyo)**，離台灣最近
3. 等 1～2 分鐘，專案建立完成。

> 免費方案的專案如果連續 7 天沒有任何使用會被暫停。長輩每天按平安鈴就算使用，正常運作不會被暫停。

## 步驟 2　建立資料庫

1. 左側選單 **SQL Editor** → **New query**。
2. 打開 `supabase/schema.sql`，**整份複製貼上** → 按 **Run**。
3. 看到 `Success` 就完成了。

如果出現 `extension "pg_cron" is not available` 之類的錯誤：左側 **Database → Extensions**，搜尋 `pg_cron` 和 `pg_net` 各按一下啟用，再回來重新 Run 一次（這份 SQL 可以重複執行，不會刪資料）。

這一步建立了：長輩名冊、每日回報、關懷個案（六階段）、處理紀錄、每分鐘自動檢查逾時的排程，以及所有權限規則。

## 步驟 3　建立第一個管理者帳號

1. **Authentication → Sign In / Providers**（或 Authentication → Settings）→ 找到 **Allow new users to sign up**，**關掉**。這樣只有您建立的帳號能登入。
2. **Authentication → Users → Add user → Create new user**：
   - 填您的 Email 和密碼
   - 勾選 **Auto Confirm User**
3. 回到 **SQL Editor**，執行（把 Email 換成您的）：

```sql
update public.profiles
set role = 'admin', active = true, name = '林老師'
where id = (select id from auth.users where email = 'your@email.com');
```

角色說明：`volunteer` 志工、`chief` 里長、`social` 社工、`admin` 管理者。里長、社工、管理者可以新增與編輯長輩；只有管理者能開通帳號、改升級規則。

## 步驟 4　把 Supabase 接到網頁

1. Supabase 左側 **Project Settings → API Keys**（或專案首頁右上的 **Connect** 按鈕）。
2. 複製兩樣東西：
   - **Project URL**（像 `https://abcdefgh.supabase.co`）
   - **anon public** key（或 `sb_publishable_` 開頭的 Publishable key）
3. 打開 `config.js`，貼進去：

```js
window.PEACE_CONFIG = {
  url: "https://abcdefgh.supabase.co",
  key: "eyJhbGciOi...（anon key）",
  vapidPublicKey: ""          // 步驟 7 再填
};
```

> 這把 anon / publishable key 本來就是設計給前端公開用的，放進 GitHub 沒問題；真正的保護是步驟 2 建立的權限規則（RLS）。**絕對不要**把 `service_role` 或 `sb_secret_` 開頭的金鑰放進任何前端檔案。

4. 把 `peacebell/` 整個資料夾上傳到 GitHub（網頁上 **Add file → Upload files** 即可）。等 1～2 分鐘 GitHub Pages 更新。

## 步驟 5　第一次使用

1. 打開 `care.html`，用步驟 3 的帳號登入。
2. 右上 **☰ 選單**：
   - 「我的資料」填稱呼和手機（長輩按「打給志工」會撥這支）
   - 「升級規則」填里名；預設「主責 30 分鐘沒處理 → 轉交備援」「開案 60 分鐘仍未平安 → 通報里長／社工」
3. 按 **＋ 新增長輩** → 儲存後會跳出專屬連結 → 用 LINE 傳給家屬，在**長輩的手機**打開並「加入主畫面」。
4. 有舊版平安鈴的備份檔？選單 → **匯入舊版平安鈴備份檔**，長輩名冊與歷史紀錄會一起搬進來。匯入後每位長輩要重新傳一次新連結（舊的 `#e=` 連結已不再使用）。

## 步驟 6　加入其他志工、里長、社工

1. Supabase **Authentication → Users → Add user**，幫對方建帳號（勾 Auto Confirm）。
2. 對方登入 `care.html` 會看到「帳號待開通」。
3. 您在工作台 **☰ 選單 → 人員管理**，找到對方 → 填稱呼、手機、選角色 → 勾「開通」→ 儲存。
4. 回到長輩的「編輯」，設定**主責志工**與**備援志工**。

## 步驟 7　產生推播金鑰

1. 用電腦瀏覽器打開 `vapid.html` → 按「產生一組新金鑰」。
2. **公鑰**：貼到 `config.js` 的 `vapidPublicKey`，重新上傳 GitHub。
3. **公鑰**和**私鑰**都先複製到記事本，下一步要用。私鑰不要放進 GitHub。

## 步驟 8　部署推播程式（Edge Function）

1. Supabase 左側 **Edge Functions → Deploy a new function → Via Editor**。
2. 函式名稱填 `send-push`，把 `supabase/functions/send-push/index.ts` 的內容整份貼上 → **Deploy**。
3. 進入 `send-push` 的設定（Details / Settings），把 **Enforce JWT Verification（Verify JWT）關掉** → 儲存。（資料庫排程用自己的密碼呼叫它，不是用登入憑證。）
4. **Edge Functions → Secrets**（或 Project Settings → Edge Functions），新增 4 個：

| Name | Value |
|---|---|
| `CRON_SECRET` | 自己想一串長亂碼，例如 `pb-2026-k8Qz7wLm3xT` |
| `VAPID_PUBLIC_KEY` | 步驟 7 的公鑰 |
| `VAPID_PRIVATE_KEY` | 步驟 7 的私鑰 |
| `VAPID_SUBJECT` | `mailto:您的Email` |

5. 回到 **SQL Editor**，告訴資料庫推播程式在哪裡（專案代碼就是 Project URL 裡 `https://` 後面那一段）：

```sql
insert into private.config(key, value) values
  ('push_url',    'https://abcdefgh.supabase.co/functions/v1/send-push'),
  ('cron_secret', 'pb-2026-k8Qz7wLm3xT')   -- 必須和上面 CRON_SECRET 一模一樣
on conflict (key) do update set value = excluded.value;
```

## 步驟 9　每位志工開啟通知

- **Android**：用 Chrome 打開 `care.html` → 登入 → ☰ 選單 →「開啟這支手機的通知」→ 允許 →「傳一則測試」。
- **iPhone**（iOS 16.4 以上）：用 Safari 打開 `care.html` →「分享 → 加入主畫面」→ **從主畫面的「關懷工作台」圖示打開** → 重新登入 → 選單 →「開啟這支手機的通知」。iPhone 只有從主畫面打開的網頁才能收推播。

## 步驟 10　驗收整個閉環

建一位測試長輩「測試阿嬤」，回報時間設成**現在時間加 2 分鐘**，主責設自己，備援設另一個帳號。然後：

1. 不要按平安 → 2～3 分鐘內手機應收到「🔴 測試阿嬤 逾時未回報」，工作台出現在「今天需要處理」。
2. 按「❌ 聯絡不上」→ 進度變成第二階段；再按一次 → 第三階段。
3. 用長輩連結按「我今天平安」→ 個案自動結案，您會收到「🟢 已回報平安」。
4. 想測升級：到選單把「轉交備援」暫時改成 5 分鐘，建一位新的測試長輩，不處理，5 分鐘後備援帳號應收到「⏫ 轉交給您」。測完改回 30。
5. 測完把測試長輩「停止關懷」。

## 出問題時看哪裡

```sql
-- 排程有沒有在跑（應該每分鐘一筆 succeeded）
select status, start_time, return_message from cron.job_run_details order by start_time desc limit 5;

-- 推播程式回了什麼（200 正常；403 代表 CRON_SECRET 兩邊不一致；401 代表 Verify JWT 沒關）
select status_code, content, created from net._http_response order by created desc limit 5;
```

Edge Function 的錯誤訊息在 **Edge Functions → send-push → Logs**。

## 資料與個資

- 資料存在 Supabase 東京機房。建議在長輩同意書加一句「關懷紀錄存放於雲端服務（日本東京）」。
- 免費方案沒有自動備份。每月初請在工作台選單「匯出本月紀錄」存一份。
- 長輩連結只含 8 碼代碼，不含姓名電話。代碼外流時，在「專屬連結」按「重新產生」，舊連結立刻失效。
- 「停止關懷」會保留歷史紀錄；若長輩撤回同意需要刪除資料，管理者可在 Supabase **Table Editor → elders** 刪除該列，相關紀錄會一併刪除。
