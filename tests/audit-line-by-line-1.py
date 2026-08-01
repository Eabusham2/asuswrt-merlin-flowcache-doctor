#!/usr/bin/env python3
from pathlib import Path
import re, sys
root=Path(__file__).resolve().parents[1]
prod=[root/'install.sh',root/'uninstall.sh',*sorted((root/'scripts').glob('*'))]
errors=[]
fc=[]
for path in prod:
    text=path.read_text()
    for n,line in enumerate(text.splitlines(),1):
        s=line.strip()
        if re.search(r'\bfcctl\s+flush\s+--mac', s):
            fc.append((path.relative_to(root).as_posix(),n,s))
        if re.search(r'(^|\s)eval(\s|$)', line): errors.append((path,n,'eval is forbidden'))
        if re.search(r'wl\s+-i\s+.*\s+(deauth|deauthenticate|macmode|maclist)', line, re.I): errors.append((path,n,'active steering/blocking command forbidden'))
        if '`' in line: errors.append((path,n,'backtick command substitution forbidden'))
        if 'rm -rf /jffs ' in line or s=='rm -rf /jffs': errors.append((path,n,'broad JFFS deletion'))
        if re.search(r'(^|[;&|]\s*)curl\s', s) and '-f' not in line and not s.startswith('#'): errors.append((path,n,'curl must fail on HTTP errors'))
        if 'roam-nonmlo.allow' in line or 'roam-mlo.ignore' in line:
            # Installer may remove obsolete upstream files only.
            if path.name!='install.sh': errors.append((path,n,'manual device list reintroduced'))
allowed=[x for x in fc if x[0]=='scripts/fcd-lib.sh' and re.search(r'^if fcctl flush --mac "\$_m"',x[2])]
if len(allowed)!=1 or len(fc)!=1:
    errors.append((root/'scripts/fcd-lib.sh',0,f'exactly one executable/total fcctl occurrence required; found {fc}'))
for path,n,msg in errors: print(f'FAIL {path.relative_to(root) if path.is_absolute() else path}:{n}: {msg}')
if errors: sys.exit(1)
print(f'PASS audit 1: {sum(len(p.read_text().splitlines()) for p in prod)} production lines inspected')
