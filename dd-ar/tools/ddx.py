#!/usr/bin/env python3
"""Parse a DDX5/DDX6 dump (from dd-fontobj2.ps1 / dd-atlas3.ps1).

usage: ddx.py <dump.txt> <outdir>   -> writes each ITEM as a file in outdir
"""
import base64, gzip, hashlib, os, sys

def parse(path):
    raw = open(path, 'rb').read()
    lines = raw.decode('utf-8', 'replace').replace('\r\n', '\n').split('\n')
    meta = []
    items = {}
    i = 0
    while i < len(lines):
        ln = lines[i].strip()
        if ln.startswith('ITEM '):
            name = ln[5:]
            mode, nraw, sha, pieces = None, None, None, []
            j = i + 1
            while j < len(lines) and not lines[j].strip().startswith('END '):
                l2 = lines[j].strip()
                if l2.startswith('MODE '): mode = l2[5:]
                elif l2.startswith('RAW '): nraw = int(l2[4:])
                elif l2.startswith('SHA '): sha = l2[4:]
                elif l2.startswith('L '):
                    p = l2.split(' ', 3)
                    if len(p) == 4: pieces.append((int(p[1]), p[2], p[3]))
                j += 1
            data = b''
            for idx, s6, b64 in pieces:
                b = base64.b64decode(b64 + '=' * (-len(b64) % 4))
                if hashlib.sha256(b).hexdigest()[:6] != s6:
                    raise ValueError('sha6 mismatch in %s line %d' % (name, idx))
                data += b
            if mode == 'GZIP':
                data = gzip.decompress(data)
            if nraw is not None and len(data) != nraw:
                raise ValueError('%s: raw %d != %d' % (name, len(data), nraw))
            if sha and hashlib.sha256(data).hexdigest()[:16] != sha:
                raise ValueError('%s: sha16 mismatch' % name)
            items[name] = data
            i = j
        else:
            if ln: meta.append(ln)
            i += 1
    return meta, items, hashlib.sha256(raw).hexdigest()[:16]

if __name__ == '__main__':
    src, outdir = sys.argv[1], sys.argv[2]
    meta, items, sha = parse(src)
    os.makedirs(outdir, exist_ok=True)
    for k, v in items.items():
        open(os.path.join(outdir, k + '.bin'), 'wb').write(v)
    open(os.path.join(outdir, '_meta.txt'), 'w').write('\n'.join(meta) + '\n')
    print('dump sha16 %s : %d items -> %s' % (sha, len(items), outdir))
    for m in meta: print('   ', m)
