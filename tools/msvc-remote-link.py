#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""rustc linker for the *-pc-windows-msvc targets that runs MSVC link.exe on a Windows host.

The pinned rustc compiles here; link.exe links on the host, a WSL shell with interop reached
over ssh. Every input the link names by absolute path is uploaded once into a content-addressed
cache under the work directory, the arguments are rewritten to Windows paths, link.exe runs in
the Visual Studio developer environment for the target's architecture, and its outputs come
back beside the paths rustc asked for. Nothing is installed on the host. tools/platform-gate.py
uses it for the Windows leg (docs/packaging.md, "Platform gate").

OSCILLUX_WINDOWS_HOST     ssh destination of the WSL shell
OSCILLUX_WINDOWS_WORKDIR  that shell's path to a work directory on a Windows drive (/mnt/c/...)
"""
import hashlib
import io
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import uuid

# /FLAG:/absolute/path, the form rustc uses for outputs, the export list and natvis files.
FLAG_PATH = re.compile(r'^(/[A-Za-z]+:)(/.+)$')
OUTPUTS = ('/OUT:', '/IMPLIB:', '/PDB:')
# vcvarsall.bat argument for each target architecture: an x64 host building for it.
VCVARS = {'x86_64': 'x64', 'aarch64': 'x64_arm64'}
SSH = ('ssh', '-o', 'BatchMode=yes')
VSWHERE = '"/mnt/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"'
# Runs first in every remote command: an ssh shell has no live WSL_INTEROP socket of its own.
PRELUDE = r'''set -eu
for s in /run/WSL/*_interop; do
  if WSL_INTEROP=$s /mnt/c/Windows/System32/cmd.exe /c exit 0 </dev/null >/dev/null 2>&1; then export WSL_INTEROP=$s; break; fi
done
[ -n "${WSL_INTEROP:-}" ] || { echo "msvc-remote-link: WSL interop is unavailable on the host" >&2; exit 1; }
'''


class LinkError(RuntimeError):
    pass


def expand(args):
    """Expands @response-file arguments; rustc writes one when the command line is too long."""
    expanded = []
    for arg in args:
        if arg.startswith('@') and Path(arg[1:]).is_file():
            data = Path(arg[1:]).read_bytes()
            text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode()
            expanded += [line.strip().strip('"') for line in text.splitlines() if line.strip()]
        else:
            expanded.append(arg)
    return expanded


def target_arch(args):
    for arg in args:
        found = re.search(r'/rustlib/(x86_64|aarch64)-pc-windows-msvc/', arg)
        if found:
            return found.group(1)
    raise LinkError('no x86_64 or aarch64 pc-windows-msvc sysroot path among the link arguments')


def rewrite(args, work, job):
    """Returns (arguments with Windows paths, {sha256: local input}, {output name: local path}).

    work is the work directory's Windows path and job the job id. Library search paths name
    directories on this machine, which mean nothing to link.exe: rustc passes every Rust library
    by path and system libraries by name, which the developer environment's LIB resolves."""
    inputs, outputs, rewritten = {}, {}, []
    for arg in args:
        match = FLAG_PATH.match(arg)
        flag, value = match.groups() if match else ('', arg)
        if flag.upper() == '/LIBPATH:':
            continue
        if flag.upper() in OUTPUTS:
            name = Path(value).name
            outputs[name] = Path(value)
            rewritten.append(f'{flag}{work}\\jobs\\{job}\\out\\{name}')
        elif value.startswith('/') and Path(value).is_file():
            sha = hashlib.sha256(Path(value).read_bytes()).hexdigest()
            inputs[sha] = Path(value)
            rewritten.append(f'{flag}{work}\\cache\\{sha}\\{Path(value).name}')
        elif match or (value.startswith('/') and Path(value).exists()):
            raise LinkError(f'cannot forward link argument {arg}')
        else:
            rewritten.append(arg)
    return rewritten, inputs, outputs


def response_file(args):
    # link.exe reads an ANSI response file; quote each argument (none ends in a backslash).
    return ''.join('"' + arg.replace('"', '\\"') + '"\r\n' for arg in args).encode()


def remote(host, script, stdin=None, stdout=subprocess.PIPE):
    result = subprocess.run([*SSH, host, 'bash -c ' + shlex.quote(PRELUDE + script)],
                            input=stdin, stdout=stdout)
    return result


def probe(host, workdir):
    """Creates workdir's cache and jobs directories; returns (workdir's Windows path, the Visual
    Studio installation with the MSVC x64 tools, the set of cached input digests)."""
    quoted = shlex.quote(workdir)
    result = remote(host, f'''mkdir -p {quoted}/cache {quoted}/jobs
wslpath -w {quoted}
{VSWHERE} -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \\
  -property installationPath | tr -d '\\r'
ls {quoted}/cache
''')
    lines = result.stdout.decode().splitlines()
    if result.returncode != 0 or len(lines) < 2 or not lines[1]:
        raise LinkError(f'could not find the work directory and a Visual Studio with the MSVC x64 tools on {host}')
    return lines[0].strip(), lines[1].strip(), set(lines[2:])


def batch(studio, arch, commands):
    """A .bat that runs commands in the Visual Studio developer environment for arch."""
    return (f'@echo off\r\ncall "{studio}\\VC\\Auxiliary\\Build\\vcvarsall.bat" {VCVARS[arch]} >nul || exit /b 1\r\n'
            + ''.join(f'{command} || exit /b\r\n' for command in commands)).encode()


def link(args, host, workdir):
    args = expand(args)
    arch = target_arch(args)
    job = uuid.uuid4().hex
    quoted = shlex.quote(workdir)
    work, studio, cached = probe(host, workdir)
    rewritten, inputs, outputs = rewrite(args, work, job)
    if not outputs:
        raise LinkError('the link names no /OUT: path')
    script = batch(studio, arch, [f'link.exe @"{work}\\jobs\\{job}\\link.rsp"'])
    upload = io.BytesIO()
    with tarfile.open(fileobj=upload, mode='w') as archive:
        for sha, path in inputs.items():
            if sha not in cached:
                archive.add(path, arcname=f'{sha}/{path.name}', recursive=False)
        for name, data in (('link.rsp', response_file(rewritten)), ('link.bat', script)):
            info = tarfile.TarInfo(f'job/{name}')
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    # Cache entries arrive in a private directory and move into place whole, so a concurrent link
    # never reads a half-written input; an entry another link moved first is left as it is.
    result = remote(host, f'''cd {quoted}
incoming=$(mktemp -d cache/.incoming.XXXXXX)
tar -xf - -C "$incoming"
mv "$incoming/job" jobs/{job}
mkdir jobs/{job}/out
for entry in "$incoming"/*; do [ -e "$entry" ] || continue; mv -T "$entry" "cache/${{entry##*/}}" 2>/dev/null || true; done
rm -rf "$incoming"
set +e
# link.exe announces each import library it writes; rustc would report that line as a warning.
/mnt/c/Windows/System32/cmd.exe /c "$(wslpath -w jobs/{job}/link.bat)" </dev/null | tr -d '\\r' \
  | grep -v '^   Creating library ' >&2
status=${{PIPESTATUS[0]}}
set -e
tar -cf - -C jobs/{job}/out .
rm -rf jobs/{job}
exit $status
''', stdin=upload.getvalue())
    if result.returncode != 0:
        raise LinkError(f'link.exe on {host} exited {result.returncode}')
    # Files rustc did not name (the .pdb and .exp) land beside the executable or DLL.
    out = next(path for name, path in outputs.items() if name.lower().endswith(('.exe', '.dll')))
    with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
        for member in archive.getmembers():
            if not member.isfile():
                continue
            name = Path(member.name).name
            destination = outputs.get(name, out.parent / name)
            destination.write_bytes(archive.extractfile(member).read())


def main():
    host, workdir = os.environ.get('OSCILLUX_WINDOWS_HOST'), os.environ.get('OSCILLUX_WINDOWS_WORKDIR')
    if not host or not workdir:
        raise LinkError('set OSCILLUX_WINDOWS_HOST and OSCILLUX_WINDOWS_WORKDIR')
    link(sys.argv[1:], host, workdir)


if __name__ == '__main__':
    try:
        main()
    except (LinkError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f'msvc-remote-link: {error}', file=sys.stderr)
        sys.exit(1)
