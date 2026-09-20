"""Rebuild the german localization payload with arabic strings (surgical, structure-preserving)."""
import struct, sys, hashlib, json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from sf import header, metadata, write_header
from parse_obj import parse_object

HERE = Path(__file__).resolve().parent
DISP = HERE.parent / 'translation' / '_AutoTranslations.display-ready.ar.txt'
OUTDIR = HERE.parent / 'prebuilt'

def load_display():
    m = {}
    for line in DISP.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        if '=' not in line:
            continue
        k, v = line.split('=', 1)
        m[k] = v
    return m

def norm(s):
    return ' '.join(s.split())

def sha16(b): return hashlib.sha256(b).hexdigest()[:16]

def build(verbose=True):
    dg = (HERE / 'payload-german.bin').read_bytes()
    de = (HERE / 'payload-english.bin').read_bytes()
    mg, _ = metadata(dg); me, _ = metadata(de)
    og, oe = mg['objects'][1], me['objects'][1]
    pg = parse_object(dg[og['byte_start']:og['byte_start']+og['byte_size']])
    pe = parse_object(de[oe['byte_start']:oe['byte_start']+oe['byte_size']])

    en_by_id = {e['id']: e['text'].decode('utf-8') for e in pe['entries']}
    disp = load_display()
    disp_norm = {norm(k): v for k, v in disp.items()}

    n_direct = n_norm = n_keep = 0
    kept = []
    body = bytearray()
    for e in pg['entries']:
        en = en_by_id.get(e['id'])
        ar = None
        if en is not None:
            if en in disp:
                ar = disp[en]; n_direct += 1
            elif norm(en) in disp_norm:
                ar = disp_norm[norm(en)]; n_norm += 1
        if ar is None:
            ar = e['text'].decode('utf-8'); n_keep += 1; kept.append(ar)
        b = ar.encode('utf-8')
        body += dg[og['byte_start']+e['start'] : og['byte_start']+e['slen_pos']]
        body += struct.pack('<i', len(b)) + b + b'\0' * ((-len(b)) % 4)
        body += dg[og['byte_start']+e['str_end'] : og['byte_start']+e['end']]
    new_obj = bytes(pg['prefix']) + bytes(body) + bytes(pg['suffix'])
    if verbose:
        print('translated %d direct / %d normalized / %d kept german' % (n_direct, n_norm, n_keep))
        print('object %d -> %d bytes (+%d)' % (og['byte_size'], len(new_obj), len(new_obj)-og['byte_size']))

    # assemble the new file: replace the object's bytes (it is the last object, ends at EOF)
    start = og['byte_start']; end = start + og['byte_size']
    assert end == len(dg), (end, len(dg))
    new_file = bytearray(dg[:start] + new_obj)
    # patch object byte_size (LE u32 in metadata)
    struct.pack_into('<I', new_file, og['byte_size_pos'], len(new_obj))
    # patch header file_size (BE i64)
    struct.pack_into('>q', new_file, 24, len(new_file))
    return bytes(new_file), {'direct': n_direct, 'norm': n_norm, 'kept': n_keep, 'kept_texts': kept}

def is_arabic(t):
    return any(0x0600 <= ord(c) <= 0x06FF or 0xFE70 <= ord(c) <= 0xFEFF or 0xFB50 <= ord(c) <= 0xFBFF for c in t)

def verify(new_file, verbose=True):
    ok = True
    dg = (HERE / 'payload-german.bin').read_bytes()
    m, _ = metadata(new_file)
    if m['h']['file_size'] != len(new_file): print('!! file_size mismatch'); ok = False
    if m['h']['data_offset'] != 5360: print('!! data_offset changed'); ok = False
    if m['h']['metadata_size'] != 5298: print('!! metadata_size changed'); ok = False
    for o in m['objects']:
        if o['byte_start'] + o['byte_size'] > len(new_file): print('!! object out of range'); ok = False
    og = m['objects'][1]
    ob = new_file[og['byte_start']:og['byte_start']+og['byte_size']]
    p = parse_object(ob)
    if p['count'] != 547: print('!! entry count', p['count']); ok = False
    if p['entries_end'] + len(p['suffix']) != p['size']: print('!! tail mismatch'); ok = False
    # 1. prefix / suffix / ids / entry tails identical to the original
    og0 = metadata(dg)[0]['objects'][1]
    ob0 = dg[og0['byte_start']:og0['byte_start']+og0['byte_size']]
    p0 = parse_object(ob0)
    if p['prefix'] != p0['prefix']: print('!! prefix differs'); ok = False
    if p['suffix'] != p0['suffix']: print('!! suffix differs'); ok = False
    for e, e0 in zip(p['entries'], p0['entries']):
        if ob[e['start']:e['slen_pos']] != ob0[e0['start']:e0['slen_pos']]: print('!! id bytes differ'); ok = False; break
        if ob[e['str_end']:e['end']] != ob0[e0['str_end']:e0['end']]: print('!! entry tail differs'); ok = False; break
    # 2. each new string must be self-consistent: length prefix matches bytes and tails start with a sane metadata count
    for e in p['entries']:
        blen = struct.unpack_from('<i', ob, e['slen_pos'])[0]
        if blen < 0 or blen != e['str_end']-e['slen_pos']-4-((-blen) % 4):
            print('!! bad length prefix for entry', e['id'], blen); ok = False; break
        if e['meta_n'] < 0 or e['meta_n'] > 20:
            print('!! bad metadata count for entry', e['id'], e['meta_n']); ok = False; break
    # 3. kept-german entries must equal the original german text
    n_same = 0
    for e, e0 in zip(p['entries'], p0['entries']):
        if not is_arabic(e['text'].decode('utf-8', 'replace')):
            n_same += 1
            if e['text'] != e0['text']:
                print('!! kept entry differs:', e0['text'][:40]); ok = False; break
    ar = sum(1 for e in p['entries'] if is_arabic(e['text'].decode('utf-8', 'replace')))
    if verbose:
        print('verify: file %d -> %d bytes, entries %d, arabic entries %d, kept-german %d' % (len(dg), len(new_file), p['count'], ar, n_same))
    return ok, p

if __name__ == '__main__':
    nf, stats = build()
    ok, p = verify(nf)
    assert ok, 'verification failed'
    OUTDIR.mkdir(exist_ok=True)
    (OUTDIR / 'payload-ar-german.bin').write_bytes(nf)
    print('sample:', [(e['id'], e['text'].decode()) for e in p['entries'][:3]])
    print('kept german:', stats['kept_texts'][:12])
    print('sha16 new payload:', sha16(nf))
