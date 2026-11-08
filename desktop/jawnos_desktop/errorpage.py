"""The dark page the Qt views show when a load fails.

Chromium's built-in error page is white, so a failed navigation in the manager
view flashed a white "This page cannot be displayed" over the black window.
The fix is two parts: turn the built-in page off (``ErrorPageEnabled``) and
put this one in its place. It is the panel's language -- black ground, a
rounded card, the jawn yellow for the retry -- and it escapes everything it is
given, because the error string and the URL come from the network.

It is also the single source of the Browser's error page: ``browser.py`` used
to carry its own copy, and the two drifted.
"""

import html
import urllib.parse


def _scheme(url):
    try:
        return urllib.parse.urlsplit(url or "").scheme.lower()
    except ValueError:
        return ""


def dark_page(message="", url="", title="This page cannot be displayed", hint=""):
    """The error page as HTML. Every argument is escaped."""
    safe_title = html.escape(str(title or ""))
    safe_message = html.escape(str(message or ""))
    safe_hint = html.escape(str(hint or ""))
    safe_url = html.escape(str(url or ""))
    message_html = '<p>%s</p>' % safe_message if safe_message else ""
    hint_html = '<p class="hint">%s</p>' % safe_hint if safe_hint else ""
    url_html = '<p class="u">%s</p>' % safe_url if safe_url else ""
    retry_html = ""
    if safe_url and _scheme(url) in ("http", "https"):
        retry_html = '<p><a class="retry" href="%s">Try again</a></p>' % safe_url
    return """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>%s</title>
<style>
 html,body{height:100%%;margin:0;background:#000000;color:#ededed;
           font-family:system-ui,sans-serif;}
 .wrap{max-width:660px;margin:0 auto;padding:12vh 24px;}
 .card{background:#1b1b1b;border:1px solid #2c2c2c;border-radius:18px;
       padding:22px;}
 h1{font-size:24px;margin:0 0 12px;color:#ededed;}
 p{line-height:1.5;margin:0 0 12px;color:#ededed;}
 .hint{color:#8e8e8e;font-size:14px;}
 .u{color:#8e8e8e;font-family:monospace;font-size:13px;word-break:break-all;}
 a.retry{display:inline-block;margin-top:4px;background:#ffcc00;color:#0a0a0a;
         font-weight:bold;text-decoration:none;border-radius:13px;
         padding:12px 18px;}
</style></head>
<body><div class="wrap"><div class="card">
<h1>%s</h1>
%s
%s
%s
%s
</div></div></body></html>""" % (
        safe_title, safe_title, message_html, hint_html, url_html, retry_html)


def watch(page_obj, hint=""):
    """Show the dark page whenever this page's main frame fails to load.

    ``loadingChanged`` (Qt 6.5+) distinguishes a failed navigation from a
    stopped one, so a user navigating away is not turned into an error. The
    manager view does not use this: it retries first and calls ``dark_page``
    itself once the retries are spent.
    """
    from PySide6.QtWebEngineCore import QWebEngineLoadingInfo

    failed = QWebEngineLoadingInfo.LoadStatus.LoadFailedStatus

    def changed(info):
        try:
            if info.status() != failed:
                return
            if info.isErrorPage():
                return
            page_obj.setHtml(dark_page(info.errorString(), info.url().toString(),
                                       hint=hint))
        except Exception:
            pass

    page_obj.loadingChanged.connect(changed)
