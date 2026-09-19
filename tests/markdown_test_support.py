"""Build the same pinned parser as the app for standalone AppKit regression executables."""
from pathlib import Path
import subprocess

def markdown_flags():
    package = Path(__file__).resolve().parent / 'markdown'
    subprocess.run(['swift', 'build', '--package-path', str(package), '-c', 'debug'], check=True, stdout=subprocess.DEVNULL)
    binary = Path(subprocess.check_output(['swift', 'build', '--package-path', str(package), '-c', 'debug', '--show-bin-path'], text=True).strip())
    flags = ['-I', str(binary / 'Modules'), '-I', str(binary), '-L', str(binary), '-lMarkdownRuntime', '-Xlinker', '-rpath', '-Xlinker', str(binary)]
    for path in binary.glob('*.build/module.modulemap'):
        flags += ['-Xcc', '-fmodule-map-file=' + str(path)]
    for path in (package / '.build/checkouts').rglob('module.modulemap'):
        flags += ['-Xcc', '-fmodule-map-file=' + str(path), '-Xcc', '-I' + str(path.parent)]
    return flags
