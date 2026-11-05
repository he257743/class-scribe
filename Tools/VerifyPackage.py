"""Check app ZIP structure, Unicode filenames, and executable permissions."""
from pathlib import Path, PurePosixPath
from zipfile import ZipFile
import plistlib
import stat
import sys

path = Path(sys.argv[1])
with ZipFile(path) as archive:
    assert archive.testzip() is None, "Corrupt ZIP member"
    members = archive.infolist()
    for member in members:
        name = PurePosixPath(member.filename)
        assert not name.is_absolute() and ".." not in name.parts, "Unsafe ZIP path"
        assert name.parts[0] == "听课译记.app", "Unexpected archive root"
        if not member.filename.isascii():
            assert member.flag_bits & 0x800, "Missing UTF-8 filename flag"
    executable = archive.getinfo("听课译记.app/Contents/MacOS/ClassScribe")
    assert (executable.external_attr >> 16) & stat.S_IXUSR, "Executable permission lost"
    archive.getinfo("听课译记.app/Contents/Resources/AppIcon.icns")
    info = plistlib.loads(archive.read("听课译记.app/Contents/Info.plist"))
    for resource in ["QwenASRWorker.py", "PrepareQwenASR.py", "qwen-asr-requirements.txt"]:
        archive.getinfo("听课译记.app/Contents/Resources/" + resource)
    assert info["CFBundleExecutable"] == "ClassScribe"
    assert info["LSMinimumSystemVersion"] == "26.0"
print(f"PASS: UTF-8 ZIP, app resources, executable permissions, version {info['CFBundleShortVersionString']}")
