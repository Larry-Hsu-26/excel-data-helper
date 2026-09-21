# PandasAI 原始碼研讀筆記

- **對象**：https://github.com/sinaptik-ai/pandas-ai
- **版本**：`3.0.0`（`pyproject.toml`），commit `bbbb771d31062d81f6fa19bafb40620d5cbe48f4`（2025-10-28）
- **目的**：確認 LLM 設定方式、資料讀取方式、程式碼執行機制，作為架構決策依據

> ⚠️ v3 與網路上多數 v2 教學**完全不同**。v2 讓 LLM 直接寫 pandas 程式碼；v3 改成 **LLM 寫的程式碼必須呼叫 `execute_sql_query()`**，由 DuckDB 執行 SQL。請不要參考 v2 範例。

---

## 1. 授權邊界

`LICENSE` 明確切分：

> All content that resides under any `pandasai/ee/` directory … are licensed under the license defined in `pandasai/ee/LICENSE`.

`pandasai/ee/LICENSE` 是 **PandasAI Enterprise License**：在 production 使用需要有效訂閱。

### 實際範圍

| 路徑 | 內容 | 行數 | 我們的處置 |
|---|---|---|---|
| `pandasai/ee/skills/` | `@skill` decorator + `SkillsManager` | 226 | **不使用** |
| `extensions/ee/connectors/` | 商用資料庫 connector | — | 不安裝 |
| `extensions/ee/vectorstores/` | vector store | — | 不安裝 |

### ⚠️ 需要留意的地方

`pandasai/__init__.py` **在 import 時就載入 ee**：

```python
from pandasai.ee.skills import skill
from pandasai.ee.skills.manager import SkillsManager
```

也就是說 `import pandasai` 一定會把 ee 程式碼載進記憶體，無法只安裝非 ee 部分。

**結論**：我們只要**不呼叫** `pai.skills` / `@skill`，功能面就完全不碰 ee。但 image 內會含有 ee 原始碼 —— 若法務對此敏感，需要另外確認。**這是需要你裁決的一點。**

---

## 2. LLM 設定方式

### 2.1 核心只有抽象類別與 FakeLLM

`pandasai/llm/` 只有三個檔案：

```
__init__.py
base.py    # class LLM（抽象）
fake.py    # class FakeLLM
```

**所有真實 LLM 客戶端都在 `extensions/llms/` 下，是獨立的 pip 套件**：`pandasai-litellm`、`pandasai-openai`。

### 2.2 `LLM` 抽象類別的契約（`pandasai/llm/base.py`）

要接上自己的 LLM，只需要實作兩件事：

```python
class LLM:
    @abstractmethod
    def call(self, instruction: BasePrompt, context: AgentState = None) -> str: ...

    @property
    def type(self) -> str: ...
```

基底類別已經免費提供：

- `generate_code()` → 呼叫 `call()` 後自動 `_extract_code()`
- `_extract_code()` → 剝掉 ` ```python ` 圍欄、驗證 `ast.parse()` 可解析，失敗丟 `NoCodeFoundError`
- `prepend_system_prompt(prompt, memory)` → 把 system prompt 與對話歷史接上

**介面非常小，自幹一個 LLM 子類別的成本極低（約 40 行）。**

### 2.3 三個選項的評估（針對「內網 vLLM、OpenAI 相容 API、斷網」）

#### 選項 A：`pandasai-openai` 的 `OpenAI` —— ❌ **不可行**

`extensions/llms/openai/pandasai_openai/openai.py` 有一份**寫死的型號白名單**：

```python
_supported_chat_models = [
    "gpt-3.5-turbo", ..., "gpt-4o", "gpt-4.1-mini", "gpt-4.1-nano", ...
]
...
if model_name in self._supported_chat_models:
    self._is_chat_model = True
    self.client = openai.OpenAI(**self._client_params).chat.completions
...
else:
    raise UnsupportedModelError(self.model)
```

vLLM 的 served model name（例如 `Qwen2.5-32B-Instruct`）**不在白名單內，建構時就會直接拋 `UnsupportedModelError`**。

它確實支援 `api_base`（可由 `OPENAI_API_BASE` 環境變數帶入），但白名單這關過不了。要用就得 monkeypatch 或繼承覆寫 `__init__` —— 那還不如直接自幹。

#### 選項 B：`pandasai-litellm` 的 `LiteLLM` —— ⚠️ 可行但笨重

實作只有 70 行，`**kwargs` 全部透傳給 `litellm.completion()`：

```python
llm = LiteLLM(model="openai/<served-model-name>", api_base=..., api_key=...)
```

**可行**，`openai/` 前綴會讓 LiteLLM 走 OpenAI 相容路徑。

但代價：

1. `litellm` 是**很重的依賴**，拖進大量 transitive dependencies，image 會明顯變大
2. **斷網風險**：litellm 預設會嘗試線上抓 model cost map。需要設 `LITELLM_LOCAL_MODEL_COST_MAP=True` 才會完全離線。這種「預設連外」的行為在斷網環境是額外的失敗點，且每次升級都要重新驗證
3. 我們不部署 LiteLLM proxy，卻為了一個 70 行的 wrapper 吞下整個 litellm 函式庫

#### 選項 C：自幹 `VLLMChat(LLM)` —— ✅ **建議採用**

```python
# src/excel_data_helper/llm/vllm_chat.py
import os
from openai import OpenAI

from pandasai.llm.base import LLM
from pandasai.core.prompts.base import BasePrompt


class VLLMChat(LLM):
    """OpenAI-compatible chat client for an in-house vLLM endpoint.

    Everything comes from the environment; nothing is hardcoded.
    """

    def __init__(
        self,
        base_url: str | None = None,
        model: str | None = None,
        api_key: str | None = None,
        temperature: float = 0.0,
        max_tokens: int = 2048,
        timeout: float = 120.0,
    ) -> None:
        super().__init__(api_key=api_key or os.environ["VLLM_API_KEY"])
        self.base_url = base_url or os.environ["VLLM_BASE_URL"]
        self.model = model or os.environ["VLLM_MODEL"]
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.client = OpenAI(
            base_url=self.base_url,
            api_key=self.api_key,
            timeout=timeout,
            max_retries=2,
        )

    @property
    def type(self) -> str:
        return "vllm"

    def call(self, instruction: BasePrompt, context=None) -> str:
        memory = context.memory if context else None
        self.last_prompt = self.prepend_system_prompt(
            instruction.to_string(), memory
        )
        response = self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": "user", "content": self.last_prompt}],
            temperature=self.temperature,
            max_tokens=self.max_tokens,
        )
        return response.choices[0].message.content
```

理由：

- 依賴只有 `openai` SDK（純 HTTP client，不會連外抓 metadata）
- 沒有型號白名單，vLLM 任何 served name 都能用
- endpoint / model / key 全部從環境變數讀取，符合部署要求
- 完全在我們掌控內，之後要加 retry、逾時、token 用量記錄都好改
- FakeLLM 測試路徑完全共用同一個 `LLM` 介面

### 2.4 注入方式

```python
import pandasai as pai

pai.config.set({"llm": VLLMChat()})
```

`ConfigManager` 是 **process 層級的 singleton**（`pandasai/config.py`）。多使用者的 web 服務要注意：全域設定會被所有 request 共用。`Agent(dfs, config=...)` 這個參數已被標為 **deprecated**，會噴 `DeprecationWarning`。

> **這是一個需要討論的架構點**：全域 singleton 對多人同時使用的 web 服務是否夠用。

### 2.5 測試用 FakeLLM

`pandasai/llm/fake.py` 就在**核心套件**內，不需額外安裝：

```python
from pandasai.llm.fake import FakeLLM

llm = FakeLLM(output="""
import pandas as pd
df = execute_sql_query("SELECT * FROM my_table")
result = {"type": "number", "value": int(df["qty"].sum())}
""")
pai.config.set({"llm": llm})
```

`FakeLLM` 還會記錄 `called` 與 `last_prompt`，可以直接斷言 prompt 內容。**完全滿足「開發環境連不到內網 LLM」的測試需求。**

---

## 3. 資料讀取方式

### 3.1 `pai.read_excel()` 只是 `pd.read_excel` 的薄包裝

```python
def read_excel(filepath, sheet_name=0):
    data = pd.read_excel(filepath, sheet_name=sheet_name)
    if isinstance(data, pd.DataFrame):
        return DataFrame(data, _table_name=get_table_name_from_path(filepath))
    return {k: DataFrame(v, _table_name=...) for k, v in data.items()}
```

**沒有任何表頭偵測、沒有合併儲存格處理、沒有多層表頭攤平。**

→ **確認了 CLAUDE.md 第 3.1 節的判斷：前處理層必須我們自己做，PandasAI 幫不上忙。**

### 3.2 我們要的切入點：直接建構 `pai.DataFrame`

```python
pai.DataFrame(clean_pandas_df, _table_name="production_log")
```

`pandasai.DataFrame` 繼承自 `pd.DataFrame`。這代表：

> **前處理層跟 PandasAI 完全解耦。**我們用純 pandas / openpyxl 做表頭偵測與攤平，產出乾淨的 `pd.DataFrame`，最後一步才包成 `pai.DataFrame`。前處理層可以獨立做 TDD，不需要任何 LLM。

這對 TDD 非常有利。

### 3.3 其他讀取路徑（我們大概用不到）

- `pai.read_csv(path)`
- `pai.create(path, df, description, columns, ...)` → 落地成 `schema.yaml` + `data.parquet`（semantic layer）
- `pai.load("org/dataset")` → 讀回上面建立的 dataset
- `VirtualDataFrame` + SQL connector → 接真實資料庫

`pai.create()` 的 `columns=[{"name":..., "description":...}]` 可以**給欄位加上中文說明**，會進到 prompt 裡。製造業的欄位名常常是縮寫或代碼，這個機制可能很有價值 —— **值得列入討論**。

---

## 4. 程式碼執行機制（安全性最關鍵的部分）

### 4.1 完整流程（`pandasai/agent/base.py`）

```
Agent.chat(query)
  └─ _process_query()
       ├─ generate_code_with_retries(query)
       │    ├─ get_chat_prompt_for_sql(state)      # 組 prompt
       │    ├─ llm.generate_code(prompt)           # 呼叫 LLM，抽出程式碼
       │    ├─ CodeCleaner                          # 清理
       │    └─ CodeRequirementValidator.validate()  # 驗證
       └─ execute_with_retries(code)
            └─ execute_code(code)
                 ├─ CodeExecutor(config)
                 ├─ add_to_env("execute_sql_query", self._execute_sql_query)
                 └─ sandbox.execute(...)  或  code_executor.execute_and_return_result(code)
```

失敗時會帶著 error 重新請 LLM 產生程式碼，最多 `config.max_retries`（預設 **3**）次。

### 4.2 ⚠️ 預設**沒有任何沙箱** —— 就是裸的 `exec()`

`pandasai/core/code_execution/code_executor.py`：

```python
def execute(self, code: str) -> dict:
    try:
        exec(code, self._environment)
    except Exception as e:
        raise CodeExecutionError("Code execution failed") from e
    return self._environment
```

`get_environment()` 只塞入三個名稱：

```python
env = {
    "pd": import_dependency("pandas"),
    "plt": import_dependency("matplotlib.pyplot"),
    "np": import_dependency("numpy"),
}
```

**`__builtins__` 沒有被限制。** Python 的 `exec()` 在 globals dict 缺少 `__builtins__` 時會自動注入完整 builtins，所以 LLM 產生的程式碼可以 `import os`、`open()`、`subprocess`、讀寫任何檔案。

### 4.3 驗證層擋不住惡意程式碼

`CodeRequirementValidator.validate()` **只檢查一件事**：

```python
if "execute_sql_query" not in func_call_visitor.function_calls:
    raise ExecuteSQLQueryNotUsed(...)
```

它用 AST 收集所有 function call 名稱，確認 `execute_sql_query` 有被呼叫。**這是功能性檢查，不是安全檢查** —— 不擋 import、不擋檔案操作、不擋網路。

（`pandasai/helpers/sql_sanitizer.py` 有 `is_sql_query_safe()` 會擋 `INSERT`/`DROP`/`EXEC` 等關鍵字，但那只作用在 SQL 字串，不是 Python 程式碼。）

### 4.4 `Sandbox` 是可選的抽象介面

`pandasai/sandbox/sandbox.py` 定義抽象基底，`extensions/sandbox/` 提供 docker 實作。`Agent(dfs, sandbox=...)` 不給就走裸 `exec()`。

### 4.5 → 我們的結論

**CLAUDE.md 第 3.2 節的決策（不用 Docker-in-Docker，改為整個服務跑在受限容器中）在讀完原始碼後依然成立，而且更加必要。**

容器層必須落實：

- `--network none`
- `--read-only` + 僅限 chart 輸出目錄的 `tmpfs`
- 非 root user
- `--memory` / `--cpus` 上限
- `--pids-limit`
- `--cap-drop ALL` / `--security-opt no-new-privileges`
- 應用層再加一道**執行逾時**（PandasAI 本身**沒有** timeout 機制）

> **注意**：`max_retries=3` 代表一次提問最多可能執行 4 次 LLM 產生的程式碼。逾時要算總和，不是單次。

### 4.6 LLM 產生的程式碼長什麼樣

由 `generate_python_code_with_sql.tmpl` + `sql_functions.tmpl` 可知，prompt 告訴 LLM：

```
def execute_sql_query(sql_query: str) -> pd.DataFrame
    """This method connects to the database, executes the sql query and returns the dataframe"""
```

並要求：

> Use only relevant table for query and do aggregation, sorting, joins and groupby through sql query

最後必須宣告：

```python
result = {"type": "...", "value": ...}
```

`type` 限四種：`string` / `number` / `dataframe` / `plot`（`plot` 的 value 是圖檔路徑或 base64 PNG）。

### 4.7 SQL 實際由 DuckDB 執行

`Agent._execute_sql_query()`：對於沒有 query builder 的 DataFrame（也就是我們從 Excel 來的），走

```python
db_manager = DuckDBConnectionManager()
db_manager.register(df.schema.name, df)
...
return db_manager.sql(final_query).df()
```

**DuckDB 對 in-memory pandas DataFrame 下 SQL。** 這是 v3 的核心機制。

---

## 5. 答案可驗證性 —— 原生支援 ✅

`ResponseParser.parse(result, last_code_executed)` 會把**執行過的程式碼**塞進 response 物件：

```python
NumberResponse(result["value"], last_code_executed)
StringResponse(...)
DataFrameResponse(...)
ChartResponse(...)
```

`Agent` 另外公開：

```python
agent.last_code_generated   # property
agent.last_prompt_used      # property
```

→ **CLAUDE.md 第 3.3 節的需求（答案要附程式碼）不需要 hack，直接讀 response 物件或 agent property 即可。**

---

## 6. 依賴與離線 build 的影響

`pyproject.toml` 的 runtime 依賴：

```
python      >=3.8,<3.12      ← 確認了 python:3.11-slim 的決策
pandas      ^2.0.3
scipy       1.10.1           ← 完全釘死
matplotlib  >=3.7.1,<3.8     ← 上限很緊
pydantic    ^2.6.4
duckdb      ^1.0.0
pillow      ^10.1.0
requests    ^2.31.0
jinja2      ^3.1.3
numpy       ^1.17            ← numpy 1.x，不是 2.x
openpyxl    ^3.1.5           ← 讀 Excel 用得到
seaborn     ^0.12.2
sqlglot     ^25.0.3
pyarrow     >=14.0.1,<19.0.0
pyyaml      ^6.0.2
```

觀察：

- `scipy==1.10.1` 與 `matplotlib<3.8` 的釘法偏舊，**我們自己要裝的套件（FastAPI / Streamlit 等）要避開版本衝突**
- `openpyxl` 已經是 PandasAI 的依賴，前處理層讀合併儲存格可以直接用，不必額外加
- **`.xls`（舊格式）需要 `xlrd`，不在依賴內**。製造業很可能有 `.xls`，要決定是否支援
- 沒有 `xlsxwriter`；若要輸出 Excel 需另加

### matplotlib 中文字型

`get_environment()` 把 `plt` 直接給 LLM 用，LLM 產生的繪圖程式碼**不會**自己設字型。因此必須在**服務啟動時**（import matplotlib 之後、執行任何程式碼之前）全域設定：

```python
import matplotlib
matplotlib.use("Agg")
matplotlib.rcParams["font.sans-serif"] = ["Noto Sans CJK TC"]
matplotlib.rcParams["axes.unicode_minus"] = False
```

且 Dockerfile 要裝字型並**清掉 matplotlib font cache** 讓它重建。

---

## 7. 中文相關風險（需要實測驗證）

1. **表格名稱**：`sanitize_sql_table_name()` 把 `[^a-zA-Z0-9_]` 一律換成 `_`。**中文工作表名會整串變底線**，多個工作表可能撞名。
   → 前處理層應該自己指定**英數的 `_table_name`**，另外把中文原名放進 description 給 LLM 看。

2. **欄位名稱**：`Column(name=str(name))` **沒有**經過 sanitize，中文欄位名會原樣進 DuckDB SQL。DuckDB 支援 UTF-8 quoted identifier，但**要靠 LLM 記得加雙引號**。小模型很可能忘記 → 這是最可能的失敗點。
   → 需要實測。可能的對策：前處理層把欄位改成英數代號（`col_1`…），中文原名放進 `columns[].description`。

3. **序列化給 LLM 的內容**：`DataframeSerializer` 用 `json.dumps(..., ensure_ascii=False)` 且 `df.head().to_csv()`，**中文不會被跳脫**，這點沒問題。字串值超過 200 字元會被截斷。

---

## 8. 待討論／待決策清單

| # | 議題 | 說明 |
|---|---|---|
| 1 | **LLM 客戶端** | 建議選項 C（自幹 `VLLMChat`）。請確認是否同意，或偏好選項 B（litellm） |
| 2 | **ee 原始碼存在於 image** | 功能不用，但 `import pandasai` 一定載入。法務是否可接受？ |
| 3 | **全域 singleton config** | `pai.config.set()` 是 process 級。多人同時使用的 web 服務要怎麼處理？ |
| 4 | **中文欄位名策略** | 直接用中文（靠 LLM 加引號）vs. 改成英數代號 + description 帶中文。需實測後決定 |
| 5 | **`.xls` 舊格式** | 是否支援？支援就要加 `xlrd` |
| 6 | **semantic layer** | 是否用 `pai.create()` 的 `columns[].description` 給欄位加中文說明 |
| 7 | **執行逾時** | PandasAI 沒有 timeout；`max_retries=3` 代表單次提問最多執行 4 次程式碼。逾時機制我們要自己加 |
