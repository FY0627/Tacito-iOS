# 账单模板格式（第 1 版）

App 读账单只靠模板（ADR 0029）。模板是一个 UTF-8 的 JSON 文件：一个模板是一个对象，几个模板可以放进一个数组。
App 和 `StatementCheck` 用同一段代码读（`BKModel/StatementTemplate.swift`），**多一个键、少一个必填的键、类型不对、正则写错都整个文件不收**。
改格式时同时改那段代码、这份说明和 `StatementTests`。

## 一个模板

```json
{
  "format": "tacito-statement-template",
  "version": 1,
  "id": "example-bank-debit",
  "name": "示例银行 交易明细",
  "issuer": { "type": "bank", "name": "示例银行" },
  "detect": { "fileTypes": ["pdf"], "contains": ["示例银行交易明细"] },
  "statement": { "accountNumber": "账号：\\s*(?<number>[0-9*]{8,})", "currency": "CNY" },
  "table": { "header": ["记账日期", "交易金额", "账户余额", "对方信息"], "rows": "top" },
  "columns": { "date": "记账日期", "amount": "交易金额", "balance": "账户余额", "counterparty": ["对方信息"] },
  "values": { "dateFormats": ["yyyy-MM-dd"] },
  "rules": [ { "when": [ { "field": "counterparty", "matches": "理财" } ], "then": "internal" } ],
  "checks": { "totals": { "count": "共\\s*(?<count>\\d+)\\s*笔" } }
}
```

| 键 | 必填 | 说明 |
|---|---|---|
| `format` | 是 | 固定写 `tacito-statement-template` |
| `version` | 是 | 固定写 `1` |
| `id` | 是 | 小写字母、数字、`-`，2–64 个字。同一个 `id` 再导入会换掉旧的，改版时沿用同一个 `id` |
| `name` | 是 | App 里显示的名称：「银行 账单名称」 |
| `issuer` | 是 | 见下 |
| `detect` | 是 | 怎么认出这份账单 |
| `statement` | 否 | 表格前面的账号、币种、账单日期 |
| `table` | 是 | 表格在哪、怎么分行 |
| `columns` | 是 | 每一列用表头上的哪一格 |
| `values` | 是 | 日期写法、收支用字、外币 |
| `rules` | 否 | 哪些行不记、记成什么 |
| `checks` | 否 | 核对账单上写的合计 |

### `issuer`

- `type`：`bank` 或 `wallet`。
- `name`：银行或钱包的名称。App 用它在用户的卡里找同一家银行（账户的银行名称包含它、或它包含账户的银行名称、或去掉「中国」「银行」后一样）。
- `wallet`：只有钱包写，是 App 认得的钱包：`alipay`、`wechatpay`、`alipayhk`、`wechatpayhk`、`maya`。

### `detect`

- `fileTypes`：`csv`、`xlsx`、`xls`、`pdf`、`image`（截图、拍照）里的几种。同一份账单能导出几种格式的，每种都要试过才写。
- `contains`：文件里**都要有**的字。比较时去掉所有空白，英文不分大小写。写账单标题、固定的英文名称这类每期都一样的字，不写日期、卡号、姓名。
- `notContains`：有这些字就不是（两种账单标题很像时用）。

### `statement`

- `accountNumber`：正则，命名分组 `number`，在整份文件的文字里找第一个。打码的号码照原样取（`621234 **** 0001`）。
  App 用它和用户填的完整卡号、账号逐位比（打码位当任意数字），都没填时比后四位。
- `currency`：三个大写字母。没有币种列、也没有 `table.sectionCurrency` 时必填。
- `date`：`{ "pattern": "…(?<date>…)…", "format": "d MMM yyyy" }`。表格里的日期没写年份时用它推年份（比账单日期晚一星期以上的算去年）。没写就按今天推。

### `table`

- `header`：表头上的几格文字，**都在同一行**的那一行就是表头。比较时去掉空白，英文不分大小写；PDF 上一格字被拆成几段的（`Transaction` `Details`）也认。
  - 表格文件（CSV、Excel）：要和格子里的字整格相同。
  - **PDF、图片：把表头的每一格都写上**，不止用到的几列。列是按表头的位置切的：从这一格的左边到下一格的左边；没写的格子会被并进左边那一列。
  - PDF 每一页都要有表头；表头在第二页不重复的账单现在读不了。
- `rows`（只 PDF、图片）：一笔交易占好几行时，有金额的那一行在哪：
  - `top`：在第一行，说明写在下面（多数账单）；
  - `bottom`：在最后一行，说明写在上面（恒生这种：先一行对方，再一行编号和金额）；
  - `center`：在中间，格子里的字上下居中（招行、兴业这种：对方信息有三行时，金额和第二行对齐）。
  不写就是 `top`。离金额那一行超过两行高、字的大小差三成以上、不在同一页的字不会并进这一笔。
- `headerLines`（只 PDF、图片，1–6）：表头占几行。表头下面跟着一行英文表头、一行「( DR=Debit )」这种说明时写 2、3……，这几行不当成交易。
- `stop`：一行里有这些字，表格到此为止（到下一个表头再接着读）。写表格下面的「温馨提示」「Transaction Summary」这类。
- `ignore`：正则。PDF 是一段段字和整行都比，表格是整行（几格用空格连起来）比，符合的不要。去掉「-----」这类分隔线、页码。
- `opening` / `closing`：正则。期初、期末余额那一行（只有余额，没有交易金额）。期初余额那一行会开始新的一段（多币种账单一个币种一段），余额从它开始核对。
- `sectionCurrency`（只 PDF、图片）：正则，命名分组 `currency`。在表头上面三行里找这一段的币种（众安的「CNY 人民币」「USD 美元」）。

### `columns`

值是表头上那一格的文字（和 `table.header` 里的写法一样）。

| 键 | 必填 | 说明 |
|---|---|---|
| `date` | 是 | 日期。空着的沿用上一笔（一天几笔只写一次日期的账单） |
| `time` | 否 | 时间单独一列时 |
| `amount` | 二选一 | 金额一列。不配 `direction` 时，负数是支出、正数是收入 |
| `inflow` + `outflow` | 二选一 | 存入、支出分两列 |
| `direction` | 否 | 和 `amount` 一起用：写着「收入」「支出」的那一列，配 `values` 的三组字 |
| `balance` | 否 | 每笔之后的余额。有就一定核对，除非 `checks.balance` 写 `false` |
| `currency` | 否 | 币种列。空着的沿用这一段的上一笔 |
| `counterparty` | 否 | 数组，几列用空格连起来：对方 |
| `description` | 否 | 数组：摘要、商品说明 |
| `type` / `status` / `reference` | 否 | 交易类型、交易状态、单号：给 `rules` 用 |
| `paidWith` | 否 | 钱包账单的「付款方式」。写着 `(1234)` 这样四位尾号的，App 认成用那张卡付的（见下面「对账怎么用模板读出来的东西」） |

### `values`

- `dateFormats`（必填）：按顺序试。`yyyy` `yy` `MM` `M` `dd` `d` `MMM`（英文月份缩写）`HH` `H` `mm` `ss`，其余字照原样，空格可有可无。
  格子里前后有别的字也认（「2026-11-05 21:30:01」用 `yyyy-MM-dd` 也读得出日期）。日期和时间在一格里时把时间也写进去：`yyyy-MM-dd HH:mm:ss`。
- `timeFormats`：有 `columns.time` 时必填。
- `inflowWords` / `outflowWords` / `neutralWords`：有 `columns.direction` 时写，整格相同才算。`neutralWords` 的行（「不计收支」「/」）要由 `rules` 定方向，没定的不导入。
- `currencyNames`：币种列、`sectionCurrency` 里的中文名称 → 代码。人民币、港币、美元、日元、欧元、英镑等常见的已经认得，不用写。
- `originalAmount`：正则，命名分组 `currency` `amount`，在描述和对方里找外币原币金额（「CNY411.30 1.18504RT」）。记账时原币是交易金额，账单上的金额是实扣。

金额自己会认：千分位、`¥` `$` `HK$`、`(12.30)`、`12.30-`、`12.30 DR` 是负数、`CR` 是正数。

### `rules`

从上往下，第一条 `when` 里的条件**都**符合的就用它：

```json
{ "when": [ { "field": "status", "equals": ["交易关闭"] }, { "field": "paidWith", "equals": [""] } ], "then": "skip" }
{ "when": [ { "field": "type", "matches": "^朝朝宝转[入出]$" } ], "then": "internal" }
{ "when": [ { "field": "type", "equals": ["零钱提现"] } ], "then": "transfer", "direction": "outflow" }
```

- `field`：`type` `status` `description` `counterparty` `paidWith` `direction` `reference`，要在 `columns` 里写了。
- `equals`（整格相同，空格子是 `""`）和 `matches`（正则，不用整格）写一个。
- `then`：
  - `skip`：不是钱的进出（交易关闭没付成、失败），不记，也不算余额；
  - `internal`：同一个账户里面挪钱（招行朝朝宝、支付宝余额和余额宝之间），算余额但不记；
  - `expense` `income` `refund` `transfer` `interest` `fee`：记成什么。不写规则的按金额方向记成支出、收入。
- `direction`：`inflow` 或 `outflow`，给 `neutralWords` 的行定方向；`skip`、`internal` 不写。

### `checks`

- `balance`：有余额列时默认核对：从期初余额（没有就从第一笔的余额）往下加减，每笔写了余额的地方都要对上，顺着、倒着（新的在前）接得上都行。
  只有余额不是每笔之后的余额时才写 `false`。
- `totals`：账单上写的合计，命名分组 `count`（笔数）、`amount`（金额）：
  - `count`：总笔数，和读出的行数比（包括 `skip`、`internal` 的行）；
  - `inflow` / `outflow` / `neutral`：按账单原来的收、支、不计收支分开比，有 `count` 比笔数，有 `amount` 比金额。账单自己说「统计口径不同」的金额不要写。

**有余额或合计的账单一定要写上核对**：核对没通过的账单整份不导入，这是对得准的保证。账单上什么都没有可核对时，App 会标「没有核对」。

## 对账怎么用模板读出来的东西

App 把几份账单一起对账（`StatementImport.swift`）：

1. `skip`、`internal` 的行不记。
2. 钱包账单里 `paidWith` 有 `(1234)` 的：不是转帐的，算那张卡付的（记到那张卡上，和银行账单里同一笔合成一笔）；是转帐的，那张卡是另一边。
   没写尾号的（余额、零钱、余额宝）记到钱包上。
3. 对方信息里写了自己另一张卡的卡号（12–19 位，打码的也行，`2088` 开头的支付宝用户号不算）：算转给自己的转帐。
4. 几份账单里的同一笔（同账户、同方向、同金额币种、前后 3 天）合成一笔，每份账单最多一笔，两份钱包账单的不合。
5. 转帐只知道一边的（支付宝「提现」没写到哪张卡）：另一个账户上同一金额、前后 2 天的只有一笔时配成一对。
6. 和账本里的流水比：同账户、同方向、同金额（或外币原币、实扣一样）、前后 3 天，一笔对一笔。对上的是「已经记了」，剩下的是「漏记」。

所以规则要让读出来的**交易性质**对：转帐要标 `transfer`，钱包自己里面挪钱要标 `internal`，没付成的要 `skip`。
