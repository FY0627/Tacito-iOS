---
name: statement-template
description: 照着一份银行或钱包导出的账单（PDF、CSV、Excel），写 Tacito「导入账单」用的账单模板（.json），并用 App 同一套代码试读、核对通过。用户说「做账单模板」「适配某某银行的账单」「这份账单 App 读不了」时用。
---

# 做账单模板

App 里没有内置任何一家银行的读法，导入账单全靠模板（ADR 0029）。模板是开发者照着样本账单写好、试读通过后发给用户，用户在「我的 › 数据 › 导入账单」里和账单一起选进去。
模板格式是严格的，**只能写 [FORMAT.md](FORMAT.md) 里有的键**，多一个、少一个、类型不对，App 整个文件都不收。

## 交出去的只有模板

- 输出就是一个 `.json` 文件（一个模板对象；几家一起发时是一个数组），不加注释，不加别的键。
- 模板里只有版式：标题、表头、列名、日期写法、正则。**不写样本里的卡号、姓名、地址、金额、商户**；`detect.contains` 写每期都一样的标题文字。
- 样本账单、读出来的文字、试读的输出只放在临时目录，不进仓库、不写进模板、不贴到对外的地方（仓库是公开的）。
- 模板不放进 App 仓库，交给用户（或者放在用户指定的地方）。

## 步骤

1. **看清账单是什么文件**：CSV（看编码，支付宝是 GBK）、xlsx、xls（有的 .xls 其实是 xlsx 或网页）、PDF（有没有文字层、有没有密码）、截图。
   - PDF：`python3 scripts/extract_pdf.py 账单.pdf 临时目录/账单.json`，有密码时把密码放进环境变量、用 `--password-env 变量名`，不要写在命令行里。
     打开读出来的 .json 看每段字的位置（`x` `y` 是 0…1，原点左上角），找到表头那一行、金额在一笔里的第几行。
   - 截图：电脑上没法用 App 的文字识别（Vision）试读。能拿到同一份账单的 PDF 就照 PDF 做，`fileTypes` 加上 `image`，告诉用户截图要在手机上试。
2. **照 FORMAT.md 写模板**：先写最少的键，`table.header` 在 PDF 上把表头每一格都写上。
   - 有余额列一定写 `balance`；账单上有总笔数、收支合计的写进 `checks.totals`。**能核对的都要核对**，这是对得准的保证。
   - 规则要让交易性质对：没付成的 `skip`，同一个账户里挪钱（理财、余额宝）`internal`，转到自己别的账户的 `transfer`。
     不确定一种交易是什么，问用户，不要猜。
3. **试读**：`scripts/check.sh 模板.json 账单文件`（PDF 用第 1 步的 .json）。要有 Docker 和 `bk-swift` 镜像。
   - 先看第一行「格式正确」，不对就按提示的位置改。
   - 「核对：通过」才算读对。没通过时看提示的那一笔，用 `--rows N` 列出来对照原账单，改 `rows`、`headerLines`、`stop`、`ignore`、列的位置。
   - 逐笔看一遍：金额、正负、日期、币种、对方、记法（`-` 是按方向的支出收入）。不只看核对，摘要里混进页脚、表头的字也要去掉。
   - 同一家有几期账单的，每一期都试一遍（跨月、跨年、多页、外币）。
4. **几份一起对账**（可选）：几家的模板放一个文件夹，`scripts/check.sh 模板文件夹 账单… --ledger 账户.json`，看账单之间合成一笔、转帐配对对不对。
   账户 JSON：`[{"name": "招行", "bank": "招商银行", "last4": "0001", "type": "debit", "currency": "CNY", "cardNumber": "…"}, {"name": "支付宝", "type": "wallet", "currency": "CNY", "wallet": "alipay"}]`，用假的号码也行，只要和账单上的尾号对得上。
5. **交付**：只交模板文件，说明认哪种账单、核对了什么、哪些情况没试过（比如截图、某个币种）。

## 改了模板格式或读法时

模板格式、读法在 `ios-swift/Packages/BKCore/Sources/BKModel/StatementTemplate.swift` 和 `BKBackend/Statement/`。改了要同时改 FORMAT.md、`StatementTests`，
用 `swift test` 跑测试（Windows 上用 Docker，见 `ios-swift/README.md`），并把手上的模板都重新试读一遍。
