"""Makes assets/rules/ads-base.srs, the ad list that comes with the app, from tools/ad_base/base.txt.

Usage: python tools/make_ad_base.py <path to the sing-box program (kumo-core)>

The list (HaGeZi Pro mini, one domain a line) loses the names of adNeverBlock (lib/core/ad_lists.dart)
and is compiled to sing-box's binary rule-set format, so the app neither parses it nor waits for it.
Prints the number of domains: put it in adBaseCount (lib/core/ad_lists.dart); a test checks it.
"""
import json, os, re, subprocess, sys, tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
core = os.path.abspath(sys.argv[1])
dart = open(os.path.join(root, 'lib', 'core', 'ad_lists.dart'), encoding='utf-8').read()
body = re.search(r'const adNeverBlock = \[(.*?)\];', dart, re.S).group(1)
never = set(re.findall(r"'([^']+)'", re.sub(r'//.*', '', body)))

def kept(d):
    parts = d.split('.')
    return not any('.'.join(parts[i:]) in never for i in range(len(parts)))

domains, seen = [], set()
for line in open(os.path.join(root, 'tools', 'ad_base', 'base.txt'), encoding='utf-8'):
    d = line.strip().lower()
    if not d or d[0] in '#!' or '.' not in d or d in seen or not kept(d):
        continue
    seen.add(d)
    domains.append(d)

out = os.path.join(root, 'assets', 'rules', 'ads-base.srs')
with tempfile.TemporaryDirectory() as tmp:
    src = os.path.join(tmp, 'base.json')
    json.dump({'version': 2, 'rules': [{'domain_suffix': domains}]}, open(src, 'w', encoding='utf-8'))
    subprocess.run([core, 'rule-set', 'compile', src, '-o', out], check=True)
print(len(domains), 'domains,', os.path.getsize(out), 'bytes')
