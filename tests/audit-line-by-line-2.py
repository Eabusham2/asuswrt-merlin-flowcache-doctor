#!/usr/bin/env python3
from pathlib import Path
import re, sys

root=Path(__file__).resolve().parents[1]
lib=(root/'scripts/fcd-lib.sh').read_text()
platform=(root/'scripts/fcd-platform-gtbe19000ai.sh').read_text()
daemon=(root/'scripts/fcd-daemon.sh').read_text()
events=(root/'scripts/fcd-events.sh').read_text()
incident=(root/'scripts/fcd-incident.sh').read_text()
ctl=(root/'scripts/roamctl').read_text()
install=(root/'install.sh').read_text()
checks=[]

def need(name,cond): checks.append((name,bool(cond)))

# Base classifier ordering remains safety-critical.
pos={k:lib.find(k) for k in ['mlo-multiradio','mlo-sta-info','mlo-or-eht','mlo-table','nonmlo-explicit-legacy','unknown-unclassified']}
need('base classifier tokens present',all(v>=0 for v in pos.values()))
need('base MLO/EHT checks precede non-MLO authorization',max(pos[k] for k in ['mlo-multiradio','mlo-sta-info','mlo-or-eht','mlo-table']) < pos['nonmlo-explicit-legacy'])
need('base unknown is final classification',pos['unknown-unclassified'] > pos['nonmlo-explicit-legacy'])

# Model override must also fail closed.
ppos={k:platform.find(k) for k in ['mlo-multiradio','mlo-sta-info','mlo-or-eht','mlo-eml-capable','mlo-table','nonmlo-negotiated-ax','nonmlo-negotiated-ac','nonmlo-negotiated-n','mlo-fallback-unclassified']}
need('platform classifier tokens present',all(v>=0 for v in ppos.values()))
need('platform MLO/EHT checks precede legacy authorization',
     max(ppos[k] for k in ['mlo-multiradio','mlo-sta-info','mlo-or-eht','mlo-eml-capable','mlo-table'])
     < min(ppos[k] for k in ['nonmlo-negotiated-ax','nonmlo-negotiated-ac','nonmlo-negotiated-n']))
need('platform unknown falls back to MLO protection',ppos['mlo-fallback-unclassified'] > ppos['nonmlo-negotiated-n'])

# The only destructive path must re-check current evidence and confirmation.
start=lib.find('fcd_safe_flush()'); end=lib.find('\nfcd_radio_util()',start); body=lib[start:end]
need('safe flush fresh-classifies',body.find('fcd_classify')>=0)
need('safe flush requires confirmed non-MLO',body.find('fcd_confirmed_nonmlo')>=0)
need('safe flush requires one association',body.find('"$_ac" -eq 1')>=0)
need('checks occur before fcctl',max(body.find('fcd_classify'),body.find('fcd_confirmed_nonmlo'),body.find('"$_ac" -eq 1')) < body.find('fcctl flush'))
need('safe flush does not increment confirmations','fcd_observe_class' not in body)

# All event, delayed, and incident paths must be non-destructive until safe gate.
need('event listener has no fcctl','fcctl' not in events)
need('event listener queues only','FCD_EVENT_QUEUE' in events)
need('daemon has no fcctl','fcctl' not in daemon)
need('pending uses safe gate','process_pending()' in daemon and 'fcd_safe_flush' in daemon[daemon.find('process_pending()'):daemon.find('process_settle()')])
need('settle uses safe gate','process_settle()' in daemon and 'fcd_safe_flush' in daemon[daemon.find('process_settle()'):daemon.find('while :; do')])
need('malformed due times rejected','fcd_num "$_due"' in daemon)
need('malformed expiry times rejected','fcd_num "$_exp"' in daemon)
need('incident capture never flushes','fcctl flush' not in incident)
need('incident capture never steers or deauths',not re.search(r'\b(deauth|deauthenticate|restart_wireless|radio\s+(down|up)|wl\s+-i\s+.*\s+(down|up))\b',incident,re.I))
need('incident capture is background-triggered','fcd-incident.sh' in platform and '&' in platform[platform.find('fcd_trigger_incident()'):])
need('utilization capture classifies cause','fcd_chanim_cause_from_fields' in platform and 'retry-analysis.tsv' in incident)
need('incident retention is implemented','fcd_cleanup_incidents' in platform and 'mtime +"$FCD_LOG_RETENTION_DAYS"' in platform)

# Defaults and lifecycle.
need('automatic five-pass confirmation','FCD_CONFIRMATIONS=5' in install)
need('thirty-day retention','FCD_LOG_RETENTION_DAYS=30' in install and 'mtime +"$FCD_LOG_RETENTION_DAYS"' in lib)
need('incident capture default on','FCD_INCIDENT_CAPTURE=1' in install)
need('no force steering default','FCD_STEER_MODE=advisor' in install and 'never force-steers' in ctl)
need('syslog disabled by default','FCD_LOG_SYSLOG=0' in install)
need('installer syntax checks downloads','sh -n "$TMP/$f"' in install and 'sh -n "$TMP/uninstall.sh"' in install)
need('old runtime removed after replacement',install.find('Remove upstream runtime scripts only after') > install.find('cp "$TMP/flowcache-doctor.conf"'))
need('incident script included in lifecycle','fcd-incident.sh' in install and 'fcd-incident.sh' in (root/'uninstall.sh').read_text())
need('manual capture command available','capture)' in ctl and 'incidents)' in ctl and 'incident)' in ctl)

failed=[n for n,v in checks if not v]
for n,v in checks: print(('ok   ' if v else 'FAIL ')+n)
if failed: sys.exit(1)
print(f'PASS audit 2: {len(checks)} safety invariants verified')
