"""Build a portable UTF-8 ZIP, preserving app executable permissions."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys

app, output = map(Path, sys.argv[1:])
assert app.is_dir() and app.suffix == '.app'
temporary = output.with_suffix('.zip.tmp')
with ZipFile(temporary, 'w', compression=ZIP_DEFLATED, compresslevel=9) as archive:
    archive.write(app, app.name)
    for item in sorted(app.rglob('*')):
        assert not item.is_symlink(), 'App contains a symlink; package it explicitly before distributing.'
        archive.write(item, str(item.relative_to(app.parent)))
temporary.replace(output)
