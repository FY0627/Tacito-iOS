#!/usr/bin/env python3
"""把 PDF 账单读成 StatementCheck 认的 .json：每页的字和位置。

    python3 extract_pdf.py 账单.pdf 输出.json [--password-env 环境变量名]

和 App 读 PDF 的方式一样（App 用 PDFKit，见 Bookkeeping/App/StatementFileReader.swift）：
- 按空白切成一段段字，位置按页面大小换成 0…1，原点在左上角；
- 不是横着写的字（斜着的水印）不要。
要 PyMuPDF：pip install pymupdf。密码从环境变量读，不写在命令行里。
"""
import json
import os
import sys

try:
    import fitz  # PyMuPDF
except ImportError:
    sys.exit("要先装 PyMuPDF：pip install pymupdf")


def main():
    args = sys.argv[1:]
    password_env = None
    if "--password-env" in args:
        i = args.index("--password-env")
        password_env = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    source, target = args
    doc = fitz.open(source)
    if doc.needs_pass:
        password = os.environ.get(password_env or "", "")
        if not password or not doc.authenticate(password):
            sys.exit("这个 PDF 上了锁：用 --password-env 指定放密码的环境变量")
    pages = []
    for page in doc:
        width, height = page.rect.width, page.rect.height
        fragments = []
        raw = page.get_text("rawdict")
        for block in raw.get("blocks", []):
            for line in block.get("lines", []):
                dx, dy = line.get("dir", (1, 0))
                if abs(dy) > 0.01 or dx < 0.99:
                    continue  # 斜的、竖的字（水印）
                chars = [c for span in line.get("spans", []) for c in span.get("chars", [])]
                word = []
                for c in chars + [None]:
                    if c is None or c["c"].isspace():
                        if word:
                            x0 = min(ch["bbox"][0] for ch in word)
                            y0 = min(ch["bbox"][1] for ch in word)
                            x1 = max(ch["bbox"][2] for ch in word)
                            y1 = max(ch["bbox"][3] for ch in word)
                            fragments.append({
                                "text": "".join(ch["c"] for ch in word),
                                "x": round(x0 / width, 5), "y": round(y0 / height, 5),
                                "width": round((x1 - x0) / width, 5), "height": round((y1 - y0) / height, 5),
                            })
                            word = []
                    else:
                        word.append(c)
        pages.append(fragments)
    with open(target, "w", encoding="utf-8") as f:
        json.dump({"kind": "pdf", "name": os.path.basename(source), "pages": pages}, f, ensure_ascii=False)
    print(f"{len(pages)} 页，{sum(len(p) for p in pages)} 段字 → {target}")


if __name__ == "__main__":
    main()
