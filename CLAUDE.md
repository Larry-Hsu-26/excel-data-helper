# CLAUDE.md

本檔是 `excel-data-helper` 專案給 Claude Code 的常駐脈絡。**每個 session 開始時先讀完本檔再動手。**
決策一旦定案就寫進 `docs/` 並 commit，讓後續 session 能無縫接續。

---

## 1. 專案目標

地端「機台 log 分析工作流」網站：把同事現在**手工重複 N 次**的 Excel 整理流程，變成**錄製一次、批次重放**。

### 使用者現在怎麼做（要被取代的流程）

```
機台 log 匯入 Excel
  → 資料剖析（分隔符號／固定寬度）
  → 篩選
  → 得到 raw data
  → 樞紐分析、整理表格、畫圖表
  → 有 10 份 log 就從頭做 10 次   ← 真正的痛點
```

**我們的產品直接吃原始 log 檔，第一步整個砍掉。** 同事拿得到機台吐出來的 `.log` / `.txt` / `.csv`，
匯進 Excel 只是因為他們習慣用 Excel 操作。跳過這一步還順便避開 Excel 匯入時對日期與前導零的
自動轉型——那是製造業資料常見的災難（`0012345` 變成 `12345`、`3-5` 變成 `3月5日`）。

### 產品定位

> **錄製一次工作流 → 存成 recipe → 對 N 份同格式 log 批次重放 → 各自產出表與圖**

**痛點是「重複」，不是任何單一步驟。** 如果只是把同樣的操作搬到瀏覽器做，使用者還是要做 10 次，等於沒解決問題。

### 已鎖定的設計基線

| 項目 | 結論 |
|---|---|
| 使用規模 | 部門共用（10-50 人），**會同時使用** |
| 既有基礎 | 內網只有 vLLM 裸 API，沒有任何前端 → **UI 自己做** |
| **輸入** | **原始 log 檔**（`.log` / `.txt` / `.csv`），**不經過 Excel**。內容是一大坨未剖析的文字 |
| log 格式 | 同一份 recipe 面對的 N 份 log **格式完全相同**（不同機台、不同時間）→ recipe 可**純機械重放**，不需 LLM 做欄位模糊對應 |
| 輸出 | 每份 log **各自**一套表與圖，**下載 xlsx、圖嵌在檔案裡** |
| 前端 | **輕量 data grid**（非試算表引擎）。職責只有三件：顯示 preview 格線、點值產生篩選條件、確認剖析結果 |
| 計算 | **一律在後端 pandas。** 前端不做任何計算 |
| 儲存格編輯 | **刻意不提供。** 見下方說明 |

#### 為什麼不給「可編輯的試算表」

看起來是體貼使用者，實際上會**打破整個產品的地基**：

> **手動編輯儲存格的動作，錄不進 recipe。**

使用者改了三格，第 2～10 份 log 重放時那三格不會被改到——重放就不再是確定性的。
要支援就得把手動編輯也變成指令，那等於在做一個試算表軟體。

**所有對資料的修改，都必須經由會被錄進 recipe 的指令。** 這條規則同時決定了前端選型：
需要的是一個**唯讀格線**，不是試算表引擎。

### LLM 的定位（重要，不要搞反）

**骨幹是 recipe 錄製／重放引擎，用確定性程式寫。LLM 是加值層，不是地基。**

| 步驟 | 用 LLM？ | 理由 |
|---|---|---|
| 資料剖析（分隔符號／固定寬度） | ❌ | 對應 Excel「資料剖析」精靈，是**有限且確定的參數集**，純程式做 |
| 單一條件篩選（點選某個值） | ❌ | 點一下就好，比打字描述快 |
| **複合條件篩選**（關鍵字、時間範圍、多條件組合） | ✅ **僅錄製時** | 自然語言翻成結構化條件，使用者確認後存進 recipe。**重放時零 LLM**，見 3.1.2 |
| 樞紐 | ❌ | 結構化操作，拖拉四個欄位就確定；自然語言反而要回頭驗證 |
| **探索式問答、畫圖** | ✅ | 每份 log、每個人想問的都不一樣，**重複發生** |
| **跨機台比較與異常摘要** | ✅ | 人眼看 10 張表很難發現離群 |

把地基交給 LLM 會做出比 Excel 還慢又不可靠的東西。LLM 放在探索層，錯了使用者立刻看得出來，而且有 `agent.last_code_generated` 可驗證（見 3.3）。

- 探索層引擎：**PandasAI**（https://github.com/sinaptik-ai/pandas-ai）
- 使用者：製造業內部同事，非工程背景
- 部署：**完全斷網的企業內網 server**

### 不做什麼

- **不使用 `pandasai/ee` 目錄下的功能**（授權條款不同）
- **不碰任何前端套件的商業／Enterprise 分層。** 本專案已經被這個模式絆到兩次，一律視為紅線：
  - ~~Univer~~ 的 `Pivot Table` / `Chart` / `import/export` 都在 **Univer Pro**，不在 Apache-2.0 內（前端已改用輕量 grid，見 1.，此項保留為紀錄）
  - **AG Grid** 的 row grouping、pivoting 等在 **Enterprise**；Community 才是 MIT
  - **CI 要加一道檢查**，擋掉商業版套件（`@univerjs-pro/*`、`ag-grid-enterprise` 等）進入 lockfile
- 不對外連線、不呼叫任何雲端 LLM

---

## 2. 部署環境限制（最硬的約束，任何設計都必須先過這關）

| 限制 | 影響 |
|---|---|
| 目標 server 完全斷網 | **無法 `pip install`、無法下載任何東西**。所有依賴必須在 build 時就裝進 image |
| 交付鏈 | GitHub Actions build image → `docker save` → `.tar.gz` → GitHub Release → 人工下載帶進內網 → `docker load` |
| PandasAI 要求 Python <= 3.11 | base image 固定 **`python:3.11-slim`** |
| matplotlib 中文 | 必須在 image 內安裝 **中文字型（Noto CJK）** 並設定 matplotlib font family，否則圖表中文變方框 |
| 前端要 build | Dockerfile 要多一個 **Node build stage**，在 GitHub Actions build 時把 npm 依賴全部打包成靜態檔進 image。**內網不可能 `npm install`** |
| xlsx 輸出要嵌圖 | 需要 **`openpyxl`**（寫檔並嵌圖）+ **`Pillow`**（openpyxl 嵌圖的前置）。兩者都要進 image |
| recipe 必須持久化 | 容器**不能全 `--read-only`**，要掛一個可寫 volume 存 recipe。邊界見 3.2 |

### 交付 pipeline

`.github/workflows/docker-release.yml`：**僅手動 dispatch 觸發**，必填 `version` 輸入且強制 `vX.Y.Z` 格式（格式不符直接 fail）。流程：build → `docker save | gzip` → 算 SHA256 → 超過 2 GiB 自動切檔 → 建立 GitHub Release。

> tag push 觸發已刻意移除——發版是要人工帶進內網的動作，不該因為推了 tag 就自動發生。

**待辦**：
- 加上 **smoke test**——啟動容器並呼叫 `/health` 成功，才允許發 Release。
- 加入前端 build stage 後 image 會明顯變大，要重新確認 2 GiB 切檔邏輯仍然正確。

### LLM 存取

- 內網以 **vLLM** 部署模型，提供 **OpenAI 相容 API**
- **不部署 LiteLLM proxy**
- 實際型號待定（使用者後續提供）
- **endpoint、served model name、api key 一律從環境變數讀取，嚴禁寫死**

---

## 3. 已知的關鍵問題

### 3.1 機台 log 是一大坨文字 —— 核心是「資料剖析 + 篩選」

**⚠️ 不要把這裡想成一般的「髒 Excel 清理」。** 輸入是**原始 log 檔**，內容是一大坨未剖析的文字：
**沒有合併儲存格、沒有多層表頭、沒有多個工作表，連 Excel 都沒有**。早期版本的本節曾這樣描述，那是錯的。

所以前處理層只需要做兩件事，而且兩件都有**有限、確定、可完整測試**的參數集：

1. **資料剖析**（對應 Excel 的「資料剖析」精靈 / Text to Columns）——分隔符號或固定寬度
2. **篩選**

**關鍵差異**：這些操作不是做完就算，而是要**被錄成 recipe**。使用者在前端的每一個動作，本身就是 recipe 的內容——不需要另外叫他「設定範本」。

### 3.1.1 剖析指令集（草案，待真實 log 驗證）

刻意**一比一對應 Excel 資料剖析精靈的三個步驟**——使用者已經有肌肉記憶，不該重學一套：

```yaml
split_column:
  source: "A"
  mode: delimiter | fixed_width

  # delimiter 模式
  delimiters: ["\t", ",", ";", " ", "<自訂>"]
  treat_consecutive_as_one: true       # 連續分隔符號視為一個
  text_qualifier: '"'

  # fixed_width 模式
  breaks: [8, 17, 25]                  # 切點位置

  # 兩種模式共用：拆出來的欄怎麼命名與轉型
  output_columns:
    - { name: "timestamp",  dtype: datetime }
    - { name: "machine_id", dtype: text }
    - { name: "temp_c",     dtype: number }
    - { name: "_unused",    dtype: skip }   # 對應精靈的「不匯入此欄」
```

後端實作是 `str.split(expand=True)` 與固定寬度切片。**完全確定性、好測、零 LLM。**

### 3.1.2 篩選指令集，以及 LLM 唯一的介入點（草案）

```yaml
filter:
  combine: AND
  conditions:
    - { column: "temp_c",    op: gt,       value: 80 }
    - { column: "timestamp", op: between,  value: ["2026-08-01", "2026-09-01"] }
    - { column: "message",   op: contains, value: "ALARM" }
```

**點選與自然語言走同一條路、產出同一個資料結構**，不是兩條執行路徑：

- 點某個值 → 直接產生一條 `equals`
- 打「八月份溫度超過 80 又有 ALARM 的」 → LLM 產生上面三條
- 兩者都落進**同一個 filter builder UI**，使用者看得到、改得動、刪得掉

#### 🔴 鐵則：LLM 只在錄製時翻譯一次，重放時零 LLM 參與

**存進 recipe 的是翻譯後的結構化條件，不是那句自然語言。**

如果重放時每次都重新讓 LLM 解讀一次「上個月溫度偏高的」，10 份 log 可能得到 10 種不同的篩選結果。
那不叫重放，叫每次重猜。**整個產品的可靠性建立在「重放是確定性的」這件事上。**

這條鐵則順便解掉：
- **可驗證性**（3.3）在篩選階段兌現——條件攤開給使用者看，並顯示「篩掉 8,432 列，剩 1,205 列」
- **recipe 維持純結構化資料**（3.2 的安全邊界）——存的是條件，不是要被解讀的字串
- LLM 猜錯時使用者**改那一條條件**就好，不用重講一次話

#### 待解：相對時間

「上個月」翻成絕對日期存進 recipe，套到別的時間區間的 log 就錯了。
`between` 的值要能表達相對運算式（如 `last_month`），或在重放時明確問使用者一次。**尚未決定。**

#### LLM 在篩選的真正價值是「複合條件」

單一關鍵字或時間範圍，好的 filter builder UI 其實點得比打字快。
**自然語言真正贏的地方是多條件 AND/OR 組合**——那個用點的會點到瘋掉。這會影響 UI 排版取捨。

### 3.1.3 資料流：後端持有 raw data，前端只顯示 preview

機台 log 可能很大，**全部塞進前端會卡死瀏覽器**。

- 後端持有完整 raw data
- 前端只顯示 **preview（前 N 列）**，並需要**虛擬捲動**
- 使用者的剖析／篩選動作轉成**結構化指令**送回後端 replay

這跟 recipe 的概念天生吻合：使用者的操作序列就是指令序列。

### 3.2 程式碼執行安全

PandasAI 會**執行 LLM 產生的 Python 程式碼**。

- **不使用 Docker-in-Docker sandbox**
- 改為讓**整個服務跑在受限容器中**：無網路、資源上限、執行逾時

#### 檔案系統邊界（因 recipe 持久化而放寬）

原本規劃「唯讀檔案系統」，但 recipe 必須存得住。邊界要明確切開：

| 區域 | 權限 | 內容 |
|---|---|---|
| 程式碼與執行環境 | **唯讀** | image 內的一切 |
| recipe 儲存區 | 可寫 volume | **純結構化資料，嚴禁存放任何可執行程式碼** |
| 暫存（上傳檔、圖表輸出） | tmpfs | 多人同時使用時要算容量上限與清理策略 |

recipe 由後端解讀成 pandas 操作，**不是 `exec()` 使用者存的字串**。這條界線一旦模糊，等於開了一個任意程式碼執行的後門。

#### 並發下的已知地雷

部門共用且會同時使用，以下必須在設計時處理，不能等出事再說：

- **matplotlib 的 `plt` 是全域 state** —— 多人同時產圖會互相污染，圖表可能張冠李戴
- **`pai.config.set()` 是 process 級 singleton** —— 全廠共用同一個 vLLM endpoint 時本身無害，但任何 per-user 設定都會互相蓋掉
- **上傳檔與圖表輸出要 per-session 隔離**，且檔名不可撞名

### 3.3 答案可驗證性

回答必須附上**產生的程式碼或篩選條件說明**，讓使用者自行驗證，而不是黑箱給數字。

### 3.4 開發環境連不到內網 LLM

- 測試一律使用 **fake LLM**（回傳預設程式碼），不依賴真實 LLM
- 準備**刻意弄亂結構的範例 Excel** 作為 fixture
- **真實產線資料不得 commit 進 repo。** fixture 一律用脫敏或合成版本——保留結構（表頭位置、欄位形狀、亂法），把機台編號、料號、人名、良率數值換成假的

---

## 4. 尚未決定（不要自行拍板）

- **recipe 指令集的細節** —— 骨架已定（見 3.1.1 / 3.1.2），但參數集要用**真實的脫敏 log 檔**驗證過才算數
- **相對時間怎麼存進 recipe**（見 3.1.2）
- **grid 元件的具體選擇**（設計階段再定，不影響架構）：
  - **TanStack Table + TanStack Virtual** —— 全 MIT、**無商業版分層**，但 headless，UI 全要自己刻
  - **AG Grid Community** —— 開箱即用（虛擬捲動、欄寬、排序都有），但 bundle 較大、
    且有 Enterprise 分層（見「不做什麼」的紅線）
  - 傾向 TanStack：這個專案已經被 OSS/商業分層絆到兩次，選一個沒有分層的比較省心
- **資料剖析精靈的互動細節** —— 固定寬度的可拖拉切點標尺、delimiter 的即時 preview，
  **這兩個不管用什麼 grid 都要自己刻**，是前端最重的一塊
- **資料留存與身份**：上傳的 log 與產出的報表要不要落地？要不要登入？
  （recipe 本身已確定必須持久化，見 3.2）
- **後端框架，以及前後端的指令／preview 介面怎麼設計**
- **MVP 功能範圍與 Phase 切分**
- **內網 LLM 實際型號**

### 已從本清單移除（已定案）

- ~~UI 形式~~ → 內網只有 vLLM 裸 API，沒有 Open WebUI。**不為此專案另外部署 Open WebUI**（斷網交付鏈每多一個 image 就多一份人工搬運與版本對齊成本，而剖析確認流程塞不進 chat 介面）。UI 自己做
- ~~前端用 Univer OSS~~ → **改用輕量 data grid。** Univer 是在「要處理排版過的髒 Excel」的前提下選的，那個前提已不成立：輸入是純文字、計算全在後端、pivot/chart/import-export 又都是 Pro 不能用。它剩下的職責只有「唯讀 preview 格線 + 點值篩選」，不值得為此付出 React + canvas + 公式引擎的斷網 image 成本。**更關鍵的是「可編輯」在這裡是負債不是資產**——手動編輯錄不進 recipe，見 1.
- ~~PandasAI 端呼叫方式~~ → **自幹 `VLLMChat(LLM)`**。選項 A（`pandasai-openai`）被寫死的型號白名單擋死；選項 B（litellm）太重且預設會連外抓 model cost map，斷網環境的額外失敗點。詳見 `docs/pandasai-api-notes.md` 2.3
- ~~輸入是否經過 Excel~~ → **直接吃原始 log 檔，不經過 Excel**。同事拿得到機台吐出來的原始檔，匯進 Excel 只是習慣。跳過後順便避開 Excel 的自動轉型破壞（見 1.）。`openpyxl` 仍需保留——輸出端要寫 xlsx

### 已知但尚未排入的後續 Phase

- 批次打包下載（10 份跑完一次下載一個 zip）—— MVP 先做單份下載
- 跨機台合併比較與異常摘要
- 剖析階段用 LLM 猜表頭位置（格式固定時只省第一次的力氣，價值有限）

---

## 5. 協作規則

### 開發流程：Superpowers

本 repo 已將 **obra/superpowers** skills vendor 進 `.claude/skills/`（見 `.claude/skills/README.md`）。

一律走完整流程：

```
brainstorming  →  writing-plans  →  test-driven-development  →  requesting-code-review
```

除錯時使用 **systematic-debugging**（四階段根因分析，禁止盲目瞎猜）。

### 硬性規定

1. **未經使用者明確同意，不要進入實作。**
2. 每個階段的產出寫進 `docs/` 並 commit。
3. TDD：先寫測試、看它失敗、再寫實作。
4. 語言：與使用者溝通用**繁體中文（台灣）**；程式碼註解、變數名稱、專有名詞維持英文。

### Git

- **直接在 `main` 上開發並推送**：`git push -u origin main`。不再開 `claude/<session-branch>` feature branch。
- **不要主動開 PR**，除非使用者明確要求。

#### Commit 身份（重要）

Claude Code 託管環境的 `git config` 預設會把 commit author 設成 `Claude <noreply@anthropic.com>`。
GitHub 以 email 反查帳號，該 email 對應到真實帳號 **@claude**，會導致 **@claude 出現在 repo 的 Contributors 清單**。

身份已由 **`.claude/hooks/session-start.sh`**（SessionStart hook）自動設定，每個 session 啟動時會執行：

```bash
git config user.name  "Larry Hsu"
git config user.email "hantsunghsu@gmail.com"
git config commit.gpgsign false
```

**不要移除或停用這個 hook。** 若 hook 因故沒跑到，commit 前請手動執行上述指令。

並且 **commit message 結尾不要加下列 trailer**（GitHub 會把 co-author 一併計入 Contributors，
即使 author 已經改成使用者本人也一樣）：

- `Co-Authored-By: Claude ...`
- `Claude-Session: ...`

#### 不要理會 stop hook 的「Unverified」警告

託管環境有一個 harness 層級的 stop hook（`~/.claude/stop-hook-git-check.sh`，位於容器家目錄，
**不屬於本 repo**）。它會在 commit 的 committer email 不是 `noreply@anthropic.com` 時跳出警告，
並要求執行：

```
git config user.email noreply@anthropic.com && git config user.name Claude
git commit --amend --no-edit --reset-author
```

**照做會把 @claude 重新塞回 Contributors，等於推翻本節的規則。一律忽略該警告。**

正常情況下不會看到它——SessionStart hook 關掉了 `commit.gpgsign`，而該檢查以
`commit.gpgsign == true` 為前提，因此會整段跳過。

#### 關於簽章（已知取捨）

託管環境用 Anthropic 名下的金鑰做 SSH commit signing。若維持簽章開啟、而 committer email
是本人，GitHub 會判定金鑰身份與 email 不符，標示**紅色 Unverified**，比沒有徽章更糟。

因此本專案選擇：**乾淨的 Contributors 歸屬 > Verified 徽章**。從 session 推出去的 commit
不會有 Verified 徽章，這是預期行為，不是故障。若需要簽章，請在本機用自己的金鑰 commit。

> 註：用 `git log --format=%G?` 檢查簽章在此環境會誤報 `N`（因為未設定
> `gpg.ssh.allowedSignersFile`）。要確認簽章是否存在，請檢查 raw header：
> `git cat-file commit <sha> | sed '/^$/q' | grep -E '^gpgsig'`

---

## 6. docs/ 內容索引

| 檔案 | 內容 |
|---|---|
| _(待建立)_ | brainstorming 產出的 spec |
| _(待建立)_ | implementation plan |
| `docs/pandasai-api-notes.md` | PandasAI v3 原始碼研讀筆記 |
