"""Install the already-tested shim only in smbd's existing SysV start path."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import stat
import subprocess

root = Path('/root/mbl-splice-persistent-20261026')
shim = Path('/root/mbl-splice-1m-20261026/samba-splice-1m-v2.so')
expected = '76d89bdbe119053c1f3994e509ee8607da3bfe4cd5d647e01366771d40780122'
assert hashlib.sha256(shim.read_bytes()).hexdigest() == expected
init = Path('/etc/init.d/smbd')
old = init.read_text()
needle = 'start-stop-daemon --start --quiet --oknodo --exec $DAEMON --pidfile $PIDFILE -- -D $SMBDOPTIONS'
assert old.count(needle) == 1
assert 'startas' not in old
assert Path('/etc/rc2.d/S01smbd').resolve() == init
backup = root/'smbd.init.before'
assert not backup.exists()
shutil.copy2(init, backup)
target = Path('/usr/local/lib/samba-splice-1m-v2.so')
wrapper = Path('/usr/local/libexec/smbd-splice')
assert not target.exists() and not wrapper.exists()
wrapper.parent.mkdir(exist_ok=True, mode=0o755)
for source, destination in [(shim, target), (root/'smbd-splice', wrapper)]:
    temp = destination.with_name(destination.name+'.new')
    assert not temp.exists()
    with temp.open('xb') as out:
        out.write(source.read_bytes())
        out.flush()
        os.fsync(out.fileno())
    os.chmod(temp, 0o755)
    os.chown(temp, 0, 0)
    os.replace(temp, destination)
new = old.replace(needle, needle.replace('--pidfile', '--startas /usr/local/libexec/smbd-splice --pidfile'))
temp = init.with_name('smbd.splice-new')
assert not temp.exists()
with temp.open('x') as out:
    out.write(new)
    out.flush()
    os.fsync(out.fileno())
os.chmod(temp, stat.S_IMODE(init.stat().st_mode))
os.chown(temp, 0, 0)
subprocess.run(['sh', '-n', str(temp)], check=True)
os.replace(temp, init)
subprocess.run(['sync'], check=True)
report = dict(shim=str(target), shim_sha256=expected, wrapper=str(wrapper), backup=str(backup),
              init_before_sha256=hashlib.sha256(old.encode()).hexdigest(),
              init_after_sha256=hashlib.sha256(new.encode()).hexdigest())
(root/'installation.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
