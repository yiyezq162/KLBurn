"""Exercise the real internal renderer and print layout, including a failing control.

This is software layout evidence, not hardware acceptance. The caller supplies a
temporary test directory; no existing report or source is rewritten.
"""
import json
from pathlib import Path
import subprocess
import sys

from weasyprint import CSS, HTML


def inspect(document, filename):
    overflow = 0
    links = {}
    for page in document.pages:
        for cell in page._page_box.descendants():
            if type(cell).__name__ != "TableCellBox" or cell.element is None:
                continue
            if "f" not in cell.element.get("class", "").split():
                continue
            left = cell.content_box_x()
            right = left + cell.width
            for box in cell.descendants():
                if type(box).__name__ == "TextBox":
                    if box.position_x < left - 0.5 or box.position_x + box.width > right + 0.5:
                        overflow += 1
                if (type(box).__name__ == "BlockBox" and box.element is not None
                        and box.element.get("href") == filename):
                    links.setdefault(id(box.element), []).extend(
                        child.text for child in box.descendants()
                        if type(child).__name__ == "TextBox")
    # Check text boxes as well as bounds: clipping/hiding the link cannot pass.
    assert len(links) == 1, "Long index link missing or duplicated"
    text = "".join(next(iter(links.values())))
    assert "".join(text.split()) == filename + "(0B)", "Index text was truncated"
    return overflow


generator, scratch = map(Path, sys.argv[1:])
run = scratch / "index-layout-run"
(run / "raw/deep").mkdir(parents=True)
filename = "deep/index-layout-" + "a" * 96 + ".txt"
(run / "raw" / filename).touch()
(run / "meta.json").write_text(json.dumps({
    "klburn_version": "TEST", "company_name": "示例实验室（虚构）",
    "report_title": "内部索引排版测试", "machine_tag": "FICT-LAYOUT",
}))
output = scratch / "index-layout.html"
subprocess.run([sys.executable, str(generator), "--run-dir", str(run),
                "--out", str(output)], check=True, stdout=subprocess.DEVNULL)
html = HTML(filename=str(output))
document = html.render()
assert inspect(document, filename) == 0, "Index text crossed the file column"
pdf = document.write_pdf()
assert pdf.startswith(b"%PDF-"), "Real PDF not produced"
(scratch / "index-layout.pdf").write_bytes(pdf)
control = html.render(stylesheets=[CSS(string=
    ".idx td.f a{white-space:nowrap !important}")])
assert inspect(control, filename) > 0, "Overflow detector failed its nowrap control"
print("Actual print-layout bounds, complete link text and failing control verified")
