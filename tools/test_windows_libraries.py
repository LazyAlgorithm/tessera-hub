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
    for relative in ['msvc/crt/lib/x86_64/libcmt.lib', 'msvc/sdk/lib/um/x86_64/kernel32.lib', 'msvc/sdk/lib/ucrt/x86_64/ucrt.lib']:
        file = tools / relative
        file.parent.mkdir(parents=True, exist_ok=True)
        file.touch()
    text = '[VisualStudio]\nManuallySet = true\nLib64Paths = ' + json.dumps([(tools / 'msvc/crt/lib/x86_64').as_posix(), (tools / 'msvc/sdk/lib/um/x86_64').as_posix(), (tools / 'msvc/sdk/lib/ucrt/x86_64').as_posix()]) + '\n'
    def found():
        result = subprocess.run([os.environ['HUB_TEST_EXE'], '--headless', '--frames', '2', '--dependencycheck', '--tools-folder', str(tools)],
                                cwd=Path(os.environ['HUB_TEST_EXE']).parent, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'DEPENDENCY CHECK microsoft-libraries:' in result.stdout, result.stdout + result.stderr
        return 'DEPENDENCY CHECK microsoft-libraries: True' in result.stdout
    assert not found(), 'Missing Beef settings must trigger repair.'
    settings.write_text(text)
    assert found(), 'A configured managed compiler and complete libraries must be found.'
    settings.write_text(text.replace('ManuallySet = true', 'ManuallySet = false'))
    assert not found(), 'Disabled manual settings must trigger repair.'
    settings.write_text(text.replace(tools.as_posix(), 'C:/stale-tools'))
    assert not found(), 'Stale library paths must trigger repair.'
    settings.write_text(text.replace('[VisualStudio]', '[Unrelated]'))
    assert not found(), 'Settings in the wrong section must trigger repair.'
    settings.write_text(text)
    (tools / 'msvc/sdk/lib/ucrt/x86_64/ucrt.lib').unlink()
    assert not found(), 'A partial SDK must trigger repair.'
print('Windows library dependency regression checks passed.')

# Exercise actual registered VS/SDK discovery, preserve other settings, then compile
# with the discovered paths rather than merely checking filenames.
import tomllib
with tempfile.TemporaryDirectory(prefix='Tessera registered SDK test ') as temporary:
    tools = Path(temporary)
    settings = tools / 'beef/bin/BeefSettings.toml'
    settings.parent.mkdir(parents=True)
    settings.write_text('[Wasm]\nEmscriptenPath = "C:/preserve-this-setting"\n')
    (settings.parent / 'BeefBuild.exe').touch()
    result = subprocess.run([os.environ['HUB_TEST_EXE'], '--headless', '--frames', '2', '--dependencycheck', '--tools-folder', str(tools), '--configure-windows-libraries'], cwd=Path(os.environ['HUB_TEST_EXE']).parent, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'CONFIGURE MICROSOFT: True' in result.stdout, result.stdout + result.stderr
    data = tomllib.loads(settings.read_text())
    assert data['Wasm']['EmscriptenPath'] == 'C:/preserve-this-setting'
    paths = data['VisualStudio']['Lib64Paths']
    assert all(Path(p).is_dir() for p in paths)
    assert any('Microsoft Visual Studio' in p for p in paths)
    assert any('Windows Kits' in p for p in paths)
    compiler = Path(os.environ['HUB_TEST_COMPILER'])
    actual_settings = compiler.parent / 'BeefSettings.toml'
    previous = actual_settings.read_bytes() if actual_settings.exists() else None
    try:
        actual_settings.write_bytes(settings.read_bytes())
        project = tools / 'probe'
        (project / 'src').mkdir(parents=True)
        (project / 'BeefSpace.toml').write_text('FileVersion = 1\nProjects = { Probe = {Path = "."} }\n[Workspace]\nStartupProject = "Probe"\n[Configs.Release.Win64]\nToolset = "LLVM"\n')
        (project / 'BeefProj.toml').write_text('FileVersion = 1\nDependencies = {corlib = "*"}\n[Project]\nName = "Probe"\nTargetType = "BeefConsoleApplication"\nStartupObject = "Probe.Program"\n[Configs.Release.Win64]\nCLibType = "Static"\n')
        (project / 'src/Program.bf').write_text('using System; namespace Probe; class Program { public static void Main() { Console.WriteLine("Registered SDK verified"); } }')
        built = subprocess.run([str(compiler), '-workspace=' + str(project), '-config=Release', '-platform=Win64', '-verbosity=minimal'], capture_output=True, text=True, timeout=90)
        exe = project / 'build/Release_Win64/Probe/Probe.exe'
        assert built.returncode == 0 and exe.exists(), built.stdout + built.stderr
        ran = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
        assert ran.returncode == 0 and 'Registered SDK verified' in ran.stdout, ran.stdout + ran.stderr
    finally:
        if previous is None:
            actual_settings.unlink(missing_ok=True)
        else:
            actual_settings.write_bytes(previous)
print('Registered Microsoft SDK configuration and compiler probe passed.')
