import sys, hashlib, base64, re
from pathlib import Path
AL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
def sha6(b): return hashlib.sha256(b).hexdigest()[:6]

def try_fix(body, h):
    """return corrected body or None"""
    # 1. window removal (any k), keeps len%4==0
    for k in range(1, 40):
        for p in range(0, len(body) - k + 1):
            cand = body[:p] + body[p + k:]
            if len(cand) % 4: continue
            try: raw = base64.b64decode(cand, validate=True)
            except Exception: continue
            if sha6(raw) == h: return cand, 'removed %d chars at %d (%r)' % (k, p, body[p:p+k])
    # 2. single char substitution
    for p in range(len(body)):
        for c in AL:
            if c == body[p]: continue
            cand = body[:p] + c + body[p + 1:]
            try: raw = base64.b64decode(cand, validate=True)
            except Exception: continue
            if sha6(raw) == h: return cand, 'char %d: %s -> %s' % (p, body[p], c)
    # 3. rotation (multiples of 4)
    for p in range(0, len(body), 4):
        cand = body[p:] + body[:p]
        try: raw = base64.b64decode(cand, validate=True)
        except Exception: continue
        if sha6(raw) == h: return cand, 'rotation by %d' % p
    return None, None

files = sys.argv[1:]
fixed_any = False
for f in files:
    p = Path(f); lines = p.read_text().splitlines()
    out = []
    for l in lines:
        m = re.match(r'^(L \d{4} [0-9a-f]{6} )(.*)$', l)
        if m:
            pre, body = m.group(1), m.group(2)
            if len(body) % 4 == 0:
                try:
                    raw = base64.b64decode(body, validate=True)
                    if sha6(raw) == pre.split()[2]:
                        out.append(l); continue
                except Exception: pass
            nb, how = try_fix(body, pre.split()[2])
            if nb:
                print("%s: FIXED line %s -> %s" % (f, pre.split()[1], how))
                out.append(pre + nb); fixed_any = True; continue
            print("%s: cannot fix line %s (len %d)" % (f, pre.split()[1], len(body)))
        out.append(l)
    p.write_text("\n".join(out) + "\n")
print("done", "changed" if fixed_any else "no changes")
