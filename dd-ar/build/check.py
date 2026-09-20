import sys, hashlib, base64, re, gzip, zlib
from pathlib import Path

def sha6(b): return hashlib.sha256(b).hexdigest()[:6]
def sha16(b): return hashlib.sha256(b).hexdigest()[:16]

MARK = re.compile(r'^(L (\d{4}) ([0-9a-f]{6}) ?(.*)|ITEM (\S+)|END (\S+)|MODE (\S+)|RAW (\d+)|SHA ([0-9a-f]{16})|DDX2|GERMAN-FILE .*|GERMAN-SIZE \d+|CATALOG.*)$')

def load(files):
    lines = []
    for f in files:
        p = Path(f)
        if not p.exists(): continue
        for l in p.read_text().splitlines():
            if l.strip(): lines.append(l.rstrip())
    items = {}   # item -> dict(meta=..., lines={idx:(sha,body)})
    cur = None
    i = 0
    while i < len(lines):
        l = lines[i]
        m = re.match(r'^ITEM (\S+)$', l)
        if m:
            cur = m.group(1); items.setdefault(cur, {'lines': {}, 'meta': {}}); i += 1; continue
        m = re.match(r'^(MODE|RAW|SHA) (\S+)$', l)
        if m and cur:
            items[cur]['meta'][m.group(1)] = m.group(2); i += 1; continue
        m = re.match(r'^END (\S+)$', l)
        if m:
            cur = None; i += 1; continue
        m = re.match(r'^L (\d{4}) ([0-9a-f]{6}) ?(.*)$', l)
        if m and cur:
            idx = int(m.group(1)); h = m.group(2); body = m.group(3)
            j = i + 1
            while j < len(lines) and not MARK.match(lines[j]):
                body += lines[j]; j += 1
            items[cur]['lines'][idx] = (h, body)
            i = j; continue
        i += 1
    return items

def verify(files):
    items = load(files)
    for name, it in items.items():
        idxs = sorted(it['lines'])
        blob = b''
        bad = []
        for k in idxs:
            h, body = it['lines'][k]
            if len(body) % 4 != 0:
                bad.append((k, 'incomplete/%d' % len(body))); continue
            try: raw = base64.b64decode(body, validate=True)
            except Exception: bad.append((k, 'b64err')); continue
            if sha6(raw) != h: bad.append((k, 'hash')); continue
            blob += raw
        print("%s: lines %d..%d (%d) bytes %d  meta %s" % (name, idxs[0] if idxs else -1, idxs[-1] if idxs else -1, len(idxs), len(blob), it['meta']))
        if bad:
            print("   BAD:", [(k, w) for k, w in bad][:20])
        else:
            raw = it['meta'].get('RAW'); sha = it['meta'].get('SHA')
            mode = it['meta'].get('MODE')
            if mode == 'GZIP':
                try:
                    data = gzip.decompress(blob)
                except Exception as e:
                    data = None; print("   gunzip failed:", e)
            else:
                data = blob
            if data is not None:
                ok = (str(len(data)) == raw) and (sha16(data) == sha)
                print("   payload: len=%d (%s) sha16=%s (%s)" % (len(data), raw, sha16(data), sha))

if __name__ == '__main__':
    verify(sys.argv[1:])
