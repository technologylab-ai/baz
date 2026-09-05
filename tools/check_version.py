from pathlib import Path
import subprocess

expected = Path('.zig-version').read_text().strip()
actual = subprocess.check_output(['zig', 'version'], text=True).strip()
if actual != expected:
    raise SystemExit(f'exact compiler required: expected {expected}, found {actual}')
