"""Validate a payload with UnityPy (independent parser).
UnityPy expects little-endian header numbers; the Unity 6 file stores them big-endian,
so we patch a temporary copy ('le-header' view) and let UnityPy parse it."""
import struct, sys, io, tempfile, os
from pathlib import Path
import UnityPy
from UnityPy.helpers.TypeTreeHelper import read_typetree

def to_upy(d):
    return d   # v22 files are already in the format UnityPy expects (big-endian header)

def check(path, expect_arabic):
    d = Path(path).read_bytes()
    tmp = tempfile.mktemp(suffix='.assets')
    Path(tmp).write_bytes(to_upy(d))
    env = UnityPy.load(tmp)
    os.unlink(tmp)
    n_files = len(env.files)
    print('== %s  (%d bytes) files=%d' % (path, len(d), n_files))
    for name, f in env.files.items():
        print('   file:', name, type(f).__name__)
        try:
            print('   container:', list(f.container.keys())[:4])
        except Exception as e:
            print('   container: err', e)
        for pid, obj in f.objects.items():
            try:
                tt = obj.read_typetree(check_read=False)
            except Exception as e:
                print('   obj %s type=%s typetree failed: %s' % (pid, obj.type.name, e))
                continue
            if 'm_TableData' in tt:
                rows = tt['m_TableData']
                print('   obj %s (%s): name=%s code=%s entries=%d' % (pid, obj.type.name, tt.get('m_Name'), tt.get('m_LocaleId', {}).get('m_Code'), len(rows)))
                ara = sum(1 for r in rows if any(0x0600 <= ord(c) <= 0x06FF or 0xFE70 <= ord(c) <= 0xFEFF for c in str(r.get('m_Localized', ''))))
                print('        arabic rows:', ara)
                for r in rows[:2]:
                    print('        ', r.get('m_Id'), repr(str(r.get('m_Localized'))[:60]))
            else:
                print('   obj %s (%s): keys=%s' % (pid, obj.type.name, list(tt.keys())[:8]))

if __name__ == '__main__':
    check('payload-german.bin', False)
    check('../prebuilt/payload-ar-german.bin', True)
