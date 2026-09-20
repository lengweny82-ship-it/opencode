"""Parse the Unity Localization StringTableCollection(MonoBehaviour) object:
   walk fixed fields, then the m_TableData array, return entries + byte ranges."""
import struct
from pathlib import Path

class Cur:
    def __init__(self, d, pos):
        self.d = d; self.p = pos
    def i32(self):  v = struct.unpack_from('<i', self.d, self.p)[0]; self.p += 4; return v
    def u32(self):  v = struct.unpack_from('<I', self.d, self.p)[0]; self.p += 4; return v
    def i64(self):  v = struct.unpack_from('<q', self.d, self.p)[0]; self.p += 8; return v
    def raw(self, n): v = self.d[self.p:self.p+n]; self.p += n; return v
    def align4(self): self.p = (self.p + 3) // 4 * 4
    def string(self):
        n = self.i32()
        b = self.raw(n); self.align4()
        return b

def parse_object(obj_bytes):
    c = Cur(obj_bytes, 0)
    gameobj = (c.i32(), c.i64())           # PPtr<GameObject>
    enabled = c.raw(1); c.align4()         # UInt8 + align
    script = (c.i32(), c.i64())            # PPtr<MonoScript>
    name = c.string()
    code = c.string()                      # LocaleIdentifier.m_Code
    shared = (c.i32(), c.i64())            # PPtr<$SharedTableData>
    # MetadataCollection m_Metadata
    meta_n = c.i32(); meta_items = [c.i64() for _ in range(meta_n)]
    table_n = c.i32()
    entries_start = c.p
    entries = []
    for _ in range(table_n):
        start = c.p
        eid = c.i64()
        slen_pos = c.p
        text = c.string()
        str_end = c.p
        em_n = c.i32(); em = [c.i64() for _ in range(em_n)]
        entries.append({'id': eid, 'text': text, 'start': start, 'end': c.p,
                        'slen_pos': slen_pos, 'str_end': str_end, 'meta_n': em_n})
    entries_end = c.p
    return {
        'name': name, 'code': code, 'shared': shared, 'script': script,
        'enabled': enabled, 'gameobj': gameobj, 'meta': meta_items,
        'count': table_n, 'entries': entries,
        'prefix': obj_bytes[:entries_start], 'entries_start': entries_start,
        'entries_end': entries_end, 'suffix': obj_bytes[entries_end:],
        'cur_end': c.p, 'size': len(obj_bytes),
    }

if __name__ == '__main__':
    from sf import header, metadata
    for nm in ('german', 'english'):
        d = Path(f'payload-{nm}.bin').read_bytes()
        m, _ = metadata(d)
        o = m['objects'][1]
        ob = d[o['byte_start']:o['byte_start']+o['byte_size']]
        p = parse_object(ob)
        print('==', nm, 'name=%r code=%r shared=%s count=%d end=%d size=%d suffix=%d' % (
            p['name'].decode(), p['code'].decode(), p['shared'], p['count'], p['cur_end'], p['size'], len(p['suffix'])))
        print('   first 3:', [(e['id'], e['text'][:40]) for e in p['entries'][:3]])
        print('   last 2:', [(e['id'], e['text'][:40]) for e in p['entries'][-2:]])
        print('   empty texts:', sum(1 for e in p['entries'] if len(e['text']) == 0))
        print('   suffix head:', p['suffix'][:40].hex())
