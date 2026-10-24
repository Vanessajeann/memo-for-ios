"""Narrow the pinned FFmpeg cookie store to exact hosts and enable TLS verification."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
http = root / 'libavformat/http.c'
s = http.read_text()
call = 'get_cookies(s, &cookies, path, hoststr)'
replacement = 'get_cookies(s, &cookies, path, cookie_host)'
if call in s:
    anchor = '        char *cookies = NULL;\n'
    assert anchor in s
    s = s.replace(anchor, anchor + '        char cookie_host[1024];\n        av_url_split(NULL, 0, NULL, 0, cookie_host, sizeof(cookie_host), NULL, NULL, 0, s->location);\n', 1)
    s = s.replace(call, replacement, 1)
elif replacement not in s:
    raise SystemExit('Pinned FFmpeg HTTP cookie call changed')
old = 'if (av_strcasecmp(&domain[domain_offset], e->value))'
new = 'if (domain_offset != 0 || av_strcasecmp(domain, e->value)) /* Memo: host-only */'
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('Pinned FFmpeg cookie domain logic changed')
anchor = '        // if a cookie path is provided, ensure the request path is within that path'
secure = '''        /* Memo: never send HTTPS-source credentials after a downgrade. */
        if (av_dict_get(cookie_params, "secure", NULL, 0) &&
            (!s->hd || strcmp(s->hd->prot->name, "tls")))
            goto skip_cookie;

'''
if secure not in s:
    assert anchor in s
    s = s.replace(anchor, secure + anchor, 1)
http.write_text(s)
tls = root / 'libavformat/tls.h'
s = tls.read_text()
line = next(line for line in s.splitlines() if '{"tls_verify"' in line)
assert '.i64 = 0' in line or '.i64 = 1' in line
s = s.replace(line, line.replace('.i64 = 0', '.i64 = 1'), 1)
tls.write_text(s)
