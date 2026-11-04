# SPDX-License-Identifier: MIT
"""Keep ordinary Composer commands on the source-pinned dependency graph."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import project_inputs
from composer_cli import content_hash, read, run_native, tool_lock_in_tree
from composer_inputs import borrowed_manifest, check_manifest, packages, portable_lock


def main(arguments):
    native = os.environ['COMPOSER_PURIFIER_REAL_COMPOSER']
    legacy = os.environ['COMPOSER_PURIFIER_LEGACY_COMPOSER']
    if os.environ.get('COMPOSER_PURIFIER') == '0':
        return subprocess.call([native, *arguments])
    root = Path.cwd()
    original_arguments = arguments
    arguments = []
    index = 0
    while index < len(original_arguments):
        argument = original_arguments[index]
        if argument in ('-d', '--working-dir') and index + 1 < len(original_arguments):
            root = (root / original_arguments[index + 1]).resolve()
            index += 2
            continue
        if argument.startswith('--working-dir='):
            root = (root / argument.split('=', 1)[1]).resolve()
        else:
            arguments.append(argument)
        index += 1
    if 'global' in arguments[:1] or '--global' in arguments or '-g' in arguments:
        return subprocess.call([native, *arguments], cwd=root)
    lock_path = (root / os.environ.get('COMPOSER_PURIFIER_LOCKFILE', 'composer-purifier.lock.json')).resolve()
    if not lock_path.exists():
        print('composer-purifier: warning: no lockfile; running Composer impurely. '
              'Run composer-purifier lock to use Nix-resolved dependencies.', file=sys.stderr)
        return subprocess.call([native, *arguments], cwd=root)
    try:
        data = read(lock_path)
    except (ValueError, OSError):
        return subprocess.call([legacy, *arguments], cwd=root)
    if not data.get('projectInputs'):
        command = next((argument for argument in arguments if not argument.startswith('-')), '')
        if command == 'install':
            subprocess.run([os.environ['COMPOSER_PURIFIER_LEGACY_COMMAND'], 'prefetch',
                            '--lockfile', str(lock_path)], cwd=root, check=True)
        return subprocess.call([legacy, *arguments], cwd=root)
    native_lock = (root / os.environ.get('COMPOSER_PURIFIER_TOOL_LOCKFILE', 'composer.lock')).resolve()
    command = next((argument for argument in arguments if not argument.startswith('-')), '')
    mutation = command in {'require', 'remove', 'update', 'bump', 'config'}
    if data.get('contentHash') != content_hash(data):
        raise ValueError('the lockfile was edited; run composer-purifier lock --force')
    if not mutation:
        subprocess.run([os.environ['COMPOSER_PURIFIER_PHP'], os.environ['COMPOSER_PURIFIER_SCRIPTS'] + '/check.php',
                        str(lock_path), str(native_lock)], check=True)
        with tool_lock_in_tree(root, native_lock):
            check_manifest(root, os.environ['COMPOSER_PURIFIER_PHP'], os.environ['COMPOSER_PURIFIER_AUTOLOAD'])
    pins = project_inputs.pin([entry['reference'] for entry in data['projectInputs']], data['projectInputs'], False)
    views = project_inputs.native_views(pins, 'composer', lock_path.parent / '.composer-purifier/inputs')
    selected = packages(views)
    requested = {}
    if command == 'require':
        rewritten = []
        for argument in arguments:
            name, separator, requirement = argument.partition(':')
            if name in selected:
                if separator:
                    requested[name] = requirement
                argument = name + ':=' + selected[name]['entry']['version']
            rewritten.append(argument)
        arguments = rewritten
    with tempfile.TemporaryDirectory(prefix='composer-command-') as temporary, tool_lock_in_tree(root, native_lock):
        bindings = Path(temporary) / 'bindings.json'
        saved = (root / 'composer.lock').read_bytes()
        try:
            if command == 'install':
                subprocess.run([os.environ['COMPOSER_PURIFIER_LEGACY_COMMAND'], 'prefetch',
                                '--lockfile', str(lock_path), '--tool-lockfile', str(native_lock)],
                               cwd=root, check=True)
            with borrowed_manifest(root, selected, True, requested):
                if command == 'install':
                    code = subprocess.call([legacy, *arguments], cwd=root)
                else:
                    code = run_native(arguments, selected, root, bindings=bindings, reconstruct=True,
                                      anchors=data.get('providedRoots'))
                if code:
                    raise subprocess.CalledProcessError(code, arguments)
            if mutation:
                portable_lock(root, selected, bindings, os.environ['COMPOSER_PURIFIER_PHP'],
                              os.environ['COMPOSER_PURIFIER_AUTOLOAD'])
            else:
                (root / 'composer.lock').write_bytes(saved)
            return 0
        except BaseException:
            (root / 'composer.lock').write_bytes(saved)
            raise


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('composer-purifier: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
