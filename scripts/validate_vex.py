import sys
import json
from pathlib import Path

vex_dir = Path('.vex')
if not vex_dir.exists():
    sys.exit(0)

errors = 0
for f in sorted(vex_dir.rglob('*.json')):
    try:
        with open(f) as fh:
            doc = json.load(fh)
        required = ['@context', '@id', 'author', 'timestamp', 'version', 'statements']
        missing = [k for k in required if k not in doc]
        if missing:
            print(f"FAIL: {f} missing {missing}")
            errors += 1
        else:
            print(f"OK: {f}")
    except Exception as e:
        print(f"FAIL: {f} - {e}")
        errors += 1

sys.exit(errors)
