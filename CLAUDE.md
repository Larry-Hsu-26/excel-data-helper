# CLAUDE.md

本檔是 `excel-data-helper` 專案給 Claude Code 的常駐脈絡。**每個 session 開始時先讀完本檔再動手。**
決策一旦定案就寫進 `docs/` 並 commit，讓後續 session 能無縫接續。

---

## 1. 專案目標

地端「Excel／數據快查小幫手」：公司同事上傳 Excel，用自然語言提問，取得答案與圖表。

- 核心引擎：**PandasAI**（https://github.com/sinaptik-ai/pandas-ai）
- 使用者：製造業內部同事，非工程背景
- 部署：**完全斷網的企業內網 server**

### 不做什麼

- **不使用 `pandasai/ee` 目錄下的功能**（授權條款不同）
- 不對外連線、不呼叫任何雲端 LLM

---

## 2. 部署環境限制（最硬的約束，任何設計都必須先過這關）

| 限制 | 影響 |
|---|---|
| 目標 server 完全斷網 | **無法 `pip install`、無法下載任何東西**。所有依賴必須在 build 時就裝進 image |
| 交付鏈 | GitHub Actions build image → `docker save` → `.tar.gz` → GitHub Release → 人工下載帶進內網 → `docker load` |
| PandasAI 要求 Python <= 3.11 | base image 固定 **`python:3.11-slim`** |
| matplotlib 中文 | 必須在 image 內安裝 **中文字型（Noto CJK）** 並設定 matplotlib font family，否則圖表中文變方框 |

### 交付 pipeline

`.github/workflows/docker-release.yml`：tag push (`v*`) 或手動 dispatch 觸發，build → `docker save | gzip` → 算 SHA256 → 超過 2 GiB 自動切檔 → 建立 GitHub Release。

**待辦**：加上 **smoke test**——啟動容器並呼叫 `/health` 成功，才允許發 Release。

### LLM 存取

- 內網以 **vLLM** 部署模型，提供 **OpenAI 相容 API**
- **不部署 LiteLLM proxy**
- 實際型號待定（使用者後續提供）
- **endpoint、served model name、api key 一律從環境變數讀取，嚴禁寫死**

---

## 3. 已知的關鍵問題

### 3.1 製造業 Excel 很亂 —— 這是本專案的核心價值

實際檔案常見：合併儲存格、多層表頭、多個工作表、中文欄位名、表格上方還有標題列。

需要一個**前處理層（preprocessing layer）**：
- 偵測真正的表頭列（header detection）
- 攤平合併儲存格（unmerge / forward-fill）
- 攤平多層表頭
- 選擇工作表
- **預覽並讓使用者確認**解析結果後才進入問答

### 3.2 程式碼執行安全

PandasAI 會**執行 LLM 產生的 Python 程式碼**。

- **不使用 Docker-in-Docker sandbox**
- 改為讓**整個服務跑在受限容器中**：無網路、唯讀檔案系統、資源上限、執行逾時

### 3.3 答案可驗證性

回答必須附上**產生的程式碼或篩選條件說明**，讓使用者自行驗證，而不是黑箱給數字。

### 3.4 開發環境連不到內網 LLM

- 測試一律使用 **fake LLM**（回傳預設程式碼），不依賴真實 LLM
- 準備**刻意弄亂結構的範例 Excel** 作為 fixture

---

## 4. 尚未決定（不要自行拍板）

- **UI 形式**：獨立網頁（FastAPI / Streamlit）vs. 包成 Open WebUI 的 Tool / Pipe
- **MVP 功能範圍與 Phase 切分**
- **內網 LLM 實際型號**
- PandasAI 端呼叫方式：LiteLLM 客戶端 vs. OpenAI 客戶端（需讀完 PandasAI 原始碼後提出建議）

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

- 開發分支：`claude/<session-branch>`，由 session 指定
- push：`git push -u origin <branch>`
- **不要主動開 PR**，除非使用者明確要求

---

## 6. docs/ 內容索引

| 檔案 | 內容 |
|---|---|
| _(待建立)_ | brainstorming 產出的 spec |
| _(待建立)_ | implementation plan |
| _(待建立)_ | PandasAI API 研讀筆記 |
