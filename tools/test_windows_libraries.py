"""Exercise the catalog's real Windows library check with incomplete tool installations."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

if os.name != 'nt':
    raise SystemExit('Run this regression check on Windows.')
catalog = json.loads((Path(__file__).resolve().parents[1] / 'src/Data/catalog.json').read_text())
dependency = next(entry for entry in catalog['dependencies'] if entry['id'] == 'microsoft-libraries')
checks = dependency['found'][0]['all']
with tempfile.TemporaryDirectory(prefix='Tessera dependency test ') as temporary:
    tools = Path(temporary)
    expand = lambda text: text.replace('{tools}', tools.as_posix())
    for check in checks:
        if 'file' in check:
            file = Path(expand(check['file']['windows']))
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()
    settings = tools / 'beef/bin/BeefSettings.toml'
    text = expand(next(step['text'] for step in dependency['install']['windows'] if 'write' in step))
    def found():
        return all(Path(expand(check['file']['windows'])).is_file() if 'file' in check else
                   subprocess.run(expand(check['command']['windows']), shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                   for check in checks)
    assert not found(), 'Missing Beef settings must trigger repair.'
    settings.write_text(text)
    assert found(), 'A configured managed compiler and complete libraries must be found.'
    settings.write_text(text.replace('ManuallySet = true', 'ManuallySet = false'))
    assert not found(), 'Disabled manual settings must trigger repair.'
    settings.write_text(text.replace(tools.as_posix(), 'C:/stale-tools'))
    assert not found(), 'Stale library paths must trigger repair.'
    settings.write_text(text)
    (tools / 'msvc/sdk/lib/ucrt/x86_64/ucrt.lib').unlink()
    assert not found(), 'A partial SDK must trigger repair.'
print('Windows library dependency regression checks passed.')
