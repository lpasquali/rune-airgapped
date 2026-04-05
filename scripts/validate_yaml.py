import sys
import yaml
from pathlib import Path

errors = 0
for f in sorted(Path('.').rglob('*.yml')) + sorted(Path('.').rglob('*.yaml')):
    if '.git/' in str(f): continue
    try:
        with open(f) as fh:
            yaml.safe_load(fh)
        print(f"OK: {f}")
    except Exception as e:
        print(f"FAIL: {f} - {e}")
        errors += 1

sys.exit(errors)
