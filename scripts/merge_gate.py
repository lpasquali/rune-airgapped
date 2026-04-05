import json
import os
import sys

# Get JSON string from env var
results_str = os.environ.get('NEEDS_JSON', '{}')
try:
    results = json.loads(results_str)
except json.JSONDecodeError:
    print("BLOCKED: Invalid JSON in NEEDS_JSON")
    sys.exit(1)

# Extract failure status
failed = [k for k, v in results.items() if v == "failure"]

if failed:
    print(f"BLOCKED: {', '.join(failed)} failed")
    sys.exit(1)

print("All gates passed or were skipped")
