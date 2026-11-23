# Build the hosted privacy page: uv run --with markdown python scripts/build_privacy_page.py docs/appstore/privacy-policy.md ~/xungirl.github.io/static/flowbeat/privacy/index.html
import re, sys, markdown
src, out = sys.argv[1], sys.argv[2]
md = open(src).read()
md = re.sub(r'^---\n.*?\n---\n', '', md, flags=re.S)
md = md.replace('[contact email]', '[xungirl1024@163.com](mailto:xungirl1024@163.com)')
md = md.replace('[publication date]', 'November 22, 2026').replace('[发布日期]', '2026 年 11 月 22 日')
en, zh = md.split('\n---\n', 1)
def label(html):
    def one(t):
        heads = re.findall(r'<th[^>]*>(.*?)</th>', t.group(0), flags=re.S)
        def row(r):
            cells = iter(heads)
            return re.sub(r'<td([^>]*)>', lambda m: f'<td data-label="{re.sub("<[^>]+>", "", next(cells, ""))}"{m.group(1)}>', r.group(0))
        return re.sub(r'<tr>.*?</tr>', row, t.group(0), flags=re.S)
    return re.sub(r'<table>.*?</table>', one, html, flags=re.S)
conv = lambda s: label(markdown.markdown(s, extensions=['tables']))
html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Flowbeat Privacy Policy</title>
<meta name="description" content="Privacy policy for Flowbeat (心流) on Apple Watch and iPhone: no data collected, heart rate never leaves your devices.">
<link rel="icon" type="image/png" sizes="32x32" href="../img/favicon-32.png">
<link rel="apple-touch-icon" href="../img/icon-180.png">
<link rel="stylesheet" href="../css/doc.css">
</head>
<body>
<header class="doc-top"><div class="doc-wrap"><a href="../"><img src="../img/mark-128.png" alt="" width="24" height="24">Flowbeat</a><nav><a href="#en">English</a><a href="#zh" lang="zh-Hans">中文</a><a href="../support/">Support</a></nav></div></header>
<main class="doc-wrap">
<article id="en">
{conv(en)}
</article>
<hr>
<article id="zh" lang="zh-Hans">
{conv(zh)}
</article>
</main>
<footer class="doc-foot"><div class="doc-wrap"><a href="../">Flowbeat</a> · <a href="../support/">Support</a> · <a href="https://github.com/xungirl/Flowbeat">GitHub</a> · Not a medical device.</div></footer>
</body>
</html>
'''
open(out, 'w').write(html)
