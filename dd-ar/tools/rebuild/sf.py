import struct
from pathlib import Path

class R:
    def __init__(self, d, pos=0, endian='<'):
        self.d = d; self.p = pos; self.e = endian
    def i32(self):  v = struct.unpack_from(self.e+'i', self.d, self.p)[0]; self.p += 4; return v
    def u32(self):  v = struct.unpack_from(self.e+'I', self.d, self.p)[0]; self.p += 4; return v
    def i16(self):  v = struct.unpack_from(self.e+'h', self.d, self.p)[0]; self.p += 2; return v
    def i64(self):  v = struct.unpack_from(self.e+'q', self.d, self.p)[0]; self.p += 8; return v
    def u64(self):  v = struct.unpack_from(self.e+'Q', self.d, self.p)[0]; self.p += 8; return v
    def u8(self):   v = self.d[self.p]; self.p += 1; return v
    def raw(self, n): v = self.d[self.p:self.p+n]; self.p += n; return v
    def cstr(self):
        i = self.d.find(b'\0', self.p); s = self.d[self.p:i]; self.p = i+1; return s
    def align(self, a=4):
        self.p = (self.p + a - 1) // a * a
    def iarray(self):
        n = self.i32(); return [self.i32() for _ in range(n)]

def header(d):
    return {
        'version': struct.unpack_from('>I', d, 8)[0],
        'metadata_size': struct.unpack_from('>I', d, 20)[0],
        'file_size': struct.unpack_from('>q', d, 24)[0],
        'data_offset': struct.unpack_from('>q', d, 32)[0],
        'unknown': struct.unpack_from('>q', d, 40)[0],
        'header_size': 48,
    }

def write_header(d, h):
    d[8:12] = struct.pack('>I', h['version'])
    d[20:24] = struct.pack('>I', h['metadata_size'])
    d[24:32] = struct.pack('>q', h['file_size'])
    d[32:40] = struct.pack('>q', h['data_offset'])
    d[40:48] = struct.pack('>q', h['unknown'])
    return d

def parse_types(r, count, v=22):
    types = []
    for _ in range(count):
        t = {'class_id': r.i32()}
        if v >= 16: t['is_stripped'] = r.u8()
        if v >= 17: t['script_type_index'] = r.i16()
        if t['class_id'] == 114: t['script_id'] = r.raw(16)
        t['old_type_hash'] = r.raw(16)
        nc = r.i32(); ss = r.i32()
        t['node_count'] = nc
        t['nodes'] = r.raw(32*nc)
        t['strings'] = r.raw(ss)
        if v >= 21:
            t['type_dependencies'] = r.iarray()
        types.append(t)
    return types

def metadata(d):
    h = header(d)
    r = R(d, h['header_size'], '<')
    out = {'h': h}
    out['unity_version'] = r.cstr().decode()
    out['target_platform'] = r.i32()
    out['enable_type_tree'] = r.u8()
    out['types'] = parse_types(r, r.i32())
    oc = r.i32()
    objs = []
    for _ in range(oc):
        r.align(4)
        _pid = r.p
        o = {'path_id': r.i64(), 'byte_start_rel_pos': r.p}
        _bsr = r.u64()
        o['byte_size_pos'] = r.p
        o['byte_size'] = r.u32()
        o['type_id'] = r.u32()
        o['byte_start_rel'] = _bsr
        o['byte_start'] = o['byte_start_rel'] + h['data_offset']
        objs.append(o)
    out['objects'] = objs
    sc = r.i32()
    out['scripts'] = [ (r.i32(), (r.align(4), r.i64())[1]) for _ in range(sc) ]
    ec = r.i32()
    ext = []
    for _ in range(ec):
        e = {'temp_empty': r.cstr().decode(), 'guid': r.raw(16).hex(), 'ext_type': r.i32(), 'path': r.cstr().decode()}
        ext.append(e)
    out['externals'] = ext
    out['pos_after_externals'] = r.p
    return out, r

if __name__ == '__main__':
    for nm in ('german','english'):
        d = Path(f'payload-{nm}.bin').read_bytes()
        m, r = metadata(d)
        print('==', nm, m['h'], m['unity_version'], 'platform', m['target_platform'], 'typetree', m['enable_type_tree'])
        print('   types:', [(t['class_id'], t.get('is_stripped'), t.get('script_type_index'), t['node_count'], t['type_dependencies']) for t in m['types']])
        print('   objects:', len(m['objects']))
        for o in m['objects']:
            print('     pid=%-22d typ=%-3d start=%-7d size=%-7d end=%d  rel_end=%d' % (o['path_id'], o['type_id'], o['byte_start'], o['byte_size'], o['byte_start']+o['byte_size'], o['byte_start_rel']+o['byte_size']))
        print('   scripts:', m['scripts'])
        for e in m['externals']: print('   ext:', e['path'][:70], '| guid', e['guid'], '| type', e['ext_type'])
        print('   pos after externals:', m['pos_after_externals'], 'meta end:', m['h']['header_size']+m['h']['metadata_size'], 'data_offset:', m['h']['data_offset'])
