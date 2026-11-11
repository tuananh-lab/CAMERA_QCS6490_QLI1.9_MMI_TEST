#!/usr/bin/env python3
"""Sinh báo cáo HTML (cùng phong cách báo cáo KIMQ8550) từ thư mục báo cáo.
Dùng: html_report.py <report_dir> <output.html>
Đọc: meta.env, results.tsv, run.log"""
import html
import os
import sys

report_dir, out_path = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))


def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


meta = {}
for line in read(os.path.join(report_dir, "meta.env")).splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        meta[k.strip()] = v.strip()
g = lambda k, d="": meta.get(k, d)
e = html.escape

rows = []
for line in read(os.path.join(report_dir, "results.tsv")).splitlines():
    p = line.split("\t")
    p += [""] * (7 - len(p))
    rows.append(p[:7])

verdict = g("VERDICT", "INCOMPLETE")
vclass = {"PASS": "v-pass", "FAIL": "v-fail"}.get(verdict, "v-skip")


def fmt_dur(s):
    try:
        s = int(s)
    except ValueError:
        return "-"
    return "%dm%02ds" % (s // 60, s % 60) if s >= 60 else "%ds" % s


body_rows, cur = [], None
for rid, grp, name, res, detail, start, dur in rows:
    if grp != cur:
        cur = grp
        body_rows.append('<tr class="grp"><td colspan="5">%s</td></tr>' % e(grp))
    body_rows.append(
        '<tr class="row-%s"><td class="seq">%s</td><td>%s</td><td class="res r-%s">%s</td>'
        '<td class="num">%s</td><td class="num">%s</td></tr>'
        % (e(res), e(rid), e(name), e(res), e(res), e(start), fmt_dur(dur)))

hsp_id = g("HSP_ID", "-")
hsp_block = ""
if hsp_id and hsp_id != "-":
    hsp_block = ('<div class="idlabel">HSPTek ID</div><div class="serial">%s</div>' % e(hsp_id))

dev_id = g("DEV_ID", "unknown")
log = read(os.path.join(report_dir, "run.log"))
header = (
    "===== HSPTEK MMI TEST REPORT =====\n"
    "Product      : %s (%s)\nHSPTEK ID    : %s\nDevice ID    : %s\n"
    "Connection   : %s\nStart time   : %s\nHost         : %s\n"
    "==================================\n\n"
    % (g("PRODUCT_NAME"), g("PRODUCT_CODE"), hsp_id, dev_id,
       g("CONNECTION"), g("START_TEXT"), g("HOST")))

page = """<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{code} {hsp} {dev} - {verdict}</title>
<style>{css}</style>
</head>
<body>
<div class="wrap">

  <div class="eyebrow">
    <strong>HSPTEK</strong>
    <span>{code} &middot; {pname}</span>
    <span class="sep"></span>
    <span>MMI Test Report{cluster_txt}</span>
  </div>

  <section class="tag">
    <img class="qr" src="https://api.qrserver.com/v1/create-qr-code/?size=220x220&data={dev_q}" alt="QR {dev}" onerror="this.hidden=true">
    <div>
      {hsp_block}
      <div class="idlabel">Serial number</div>
      <div class="serial">{dev}</div>
      <div class="meta">
        <span>Bắt đầu: {start}</span>
        <span>Thời lượng: {duration}</span>
        <span>CPU: {cpu}</span>
        <span>Kết nối: {conn}</span>
      </div>
    </div>
    <div class="stamp {vclass}">{verdict}</div>
  </section>

  <div class="tally">
    <div><b class="r-PASS">{p}</b><span>Pass</span></div>
    <div><b class="r-FAIL">{f}</b><span>Fail</span></div>
    <div><b class="r-SKIP">{s}</b><span>Skip</span></div>
  </div>

  <h2>Kết quả theo thứ tự thực thi</h2>
  <table>
    <thead><tr><th class="seq">Mục</th><th>Bài test</th><th>Kết quả</th>
    <th class="num">Bắt đầu</th><th class="num">Thời gian</th></tr></thead>
    <tbody>
      {rows}
    </tbody>
  </table>

  <details>
    <summary>Log chi tiết</summary>
    <pre>
{log}
    </pre>
  </details>

  <footer>HSPTEK &middot; {code} MMI &middot; Báo cáo sinh tự động</footer>
</div>
</body>
</html>
""".format(
    cluster_txt=(" &middot; Cụm " + e(g("CLUSTER"))) if g("CLUSTER") else "",
    code=e(g("PRODUCT_CODE")), pname=e(g("PRODUCT_NAME")), hsp=e(hsp_id if hsp_id != "-" else ""),
    dev=e(dev_id), dev_q=e(dev_id), verdict=e(verdict), vclass=vclass,
    css=read(os.path.join(here, "report.css")), hsp_block=hsp_block,
    start=e(g("START_TEXT")), duration=fmt_dur(g("DURATION_S", "0")), cpu=e(g("CPU", "?")),
    conn=e(g("CONNECTION")), p=e(g("PASS", "0")), f=e(g("FAIL", "0")), s=e(g("SKIP", "0")),
    rows="\n      ".join(body_rows), log=e(log))

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(page)
print(out_path)