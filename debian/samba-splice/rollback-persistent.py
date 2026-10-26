"""Restore the exact saved SysV script; keep the versioned library for diagnosis."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

root = Path('/root/mbl-splice-persistent-20261026')
record = json.loads((root/'installation.json').read_text())
init = Path('/etc/init.d/smbd')
backup = Path(record['backup'])
assert hashlib.sha256(init.read_bytes()).hexdigest() == record['init_after_sha256'], 'Init changed since install'
assert hashlib.sha256(backup.read_bytes()).hexdigest() == record['init_before_sha256']
temp = init.with_name('smbd.splice-rollback')
assert not temp.exists()
shutil.copy2(backup, temp)
os.chown(temp, 0, 0)
with temp.open('rb') as f:
    os.fsync(f.fileno())
os.replace(temp, init)
subprocess.run(['sync'], check=True)
print('Original smbd init script restored. Run: env -u LD_PRELOAD /etc/init.d/smbd restart')
