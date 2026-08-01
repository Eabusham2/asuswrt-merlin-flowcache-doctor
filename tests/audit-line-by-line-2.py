#!/usr/bin/env python3
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
lib=(root/'scripts/fcd-lib.sh').read_text(); daemon=(root/'scripts/fcd-daemon.sh').read_text(); events=(root/'scripts/fcd-events.sh').read_text(); ctl=(root/'scripts/roamctl').read_text(); install=(root/'install.sh').read_text()
checks=[]
def need(name,cond): checks.append((name,bool(cond)))
# Classifier ordering is safety-critical.
pos={k:lib.find(k) for k in ['mlo-multiradio','mlo-sta-info','mlo-or-eht','mlo-table','nonmlo-explicit-legacy','unknown-unclassified']}
need('classifier tokens present',all(v>=0 for v in pos.values()))
need('MLO/EHT checks precede non-MLO authorization',max(pos[k] for k in ['mlo-multiradio','mlo-sta-info','mlo-or-eht','mlo-table']) < pos['nonmlo-explicit-legacy'])
need('unknown is final classification',pos['unknown-unclassified'] > pos['nonmlo-explicit-legacy'])
# The only destructive path must re-check current evidence and confirmation.
start=lib.find('fcd_safe_flush()'); end=lib.find('\nfcd_radio_util()',start); body=lib[start:end]
need('safe flush fresh-classifies',body.find('fcd_classify')>=0)
need('safe flush requires confirmed non-MLO',body.find('fcd_confirmed_nonmlo')>=0)
need('safe flush requires one association',body.find('"$_ac" -eq 1')>=0)
need('checks occur before fcctl',max(body.find('fcd_classify'),body.find('fcd_confirmed_nonmlo'),body.find('"$_ac" -eq 1')) < body.find('fcctl flush'))
need('safe flush does not increment confirmations', 'fcd_observe_class' not in body)
# All event and delayed paths must be non-destructive until safe gate.
need('event listener has no fcctl','fcctl' not in events)
need('event listener queues only','FCD_EVENT_QUEUE' in events)
need('daemon has no fcctl','fcctl' not in daemon)
need('pending uses safe gate','process_pending()' in daemon and 'fcd_safe_flush' in daemon[daemon.find('process_pending()'):daemon.find('process_settle()')])
need('settle uses safe gate','process_settle()' in daemon and 'fcd_safe_flush' in daemon[daemon.find('process_settle()'):daemon.find('while :; do')])
need('malformed due times rejected','fcd_num "$_due"' in daemon)
need('malformed expiry times rejected','fcd_num "$_exp"' in daemon)
# Defaults and lifecycle.
need('automatic five-pass confirmation','FCD_CONFIRMATIONS=5' in install)
need('thirty-day retention','FCD_LOG_RETENTION_DAYS=30' in install and 'mtime +"$FCD_LOG_RETENTION_DAYS"' in lib)
need('no force steering default','FCD_STEER_MODE=advisor' in install and 'never force-steers' in ctl)
need('syslog disabled by default','FCD_LOG_SYSLOG=0' in install)
need('installer syntax checks downloads','sh -n "$TMP/$f"' in install and 'sh -n "$TMP/uninstall.sh"' in install)
need('old runtime removed after replacement',install.find('Remove upstream runtime scripts only after') > install.find('cp "$TMP/flowcache-doctor.conf"'))
failed=[n for n,v in checks if not v]
for n,v in checks: print(('ok   ' if v else 'FAIL ')+n)
if failed: sys.exit(1)
print(f'PASS audit 2: {len(checks)} safety invariants verified')
