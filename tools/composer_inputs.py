# SPDX-License-Identifier: MIT
"""Validate Composer projections and borrow native manifest bindings."""
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path

from composer_repository import manifest


def packages(views):
    selected = {}
    for view in views:
        repository, catalog_path = Path(view['repository']), Path(view['catalog'])
        catalog = json.loads(catalog_path.read_text())
        if catalog.get('format') != 'composer':
            raise ValueError('not a Composer repository')
        for entry in catalog['packages']:
            archive = entry['archive']
            if Path(archive).name != archive or not archive.endswith('.zip'):
                raise ValueError('invalid Composer archive path')
            data = repository / archive
            if hashlib.sha256(data.read_bytes()).hexdigest() != entry['checksum']:
                raise ValueError('corrupt Nix-provided Composer archive')
            metadata = manifest(data)
            if (metadata['name'], metadata['version']) != (entry['name'], entry['version']):
                raise ValueError('inconsistent Nix-provided Composer metadata')
            source = catalog_path.parent / 'sources' / archive[:-4]
            if json.loads((source / 'composer.json').read_text()) != metadata:
                raise ValueError('inconsistent Nix-provided Composer sources')
            value = {'metadata': metadata, 'source': str(source), 'entry': entry}
            if entry['name'] in selected and selected[entry['name']]['entry'] != entry:
                raise ValueError(f"conflicting Nix sources for Composer package {entry['name']}")
            selected[entry['name']] = value
    return selected


def bind(document, selected):
    if not selected:
        return document
    for field in ('require', 'require-dev'):
        for name in document.get(field, {}):
            if name in selected:
                document[field][name] = '=' + selected[name]['entry']['version']
    return document


def restore(original, changed, selected, requested=None):
    requested = requested or {}
    for field in ('require', 'require-dev'):
        for name in changed.get(field, {}):
            if name in selected:
                if name in requested:
                    changed[field][name] = requested[name]
                elif selected[name]['entry']['version'] in str(changed[field][name]):
                    changed[field][name] = original.get(field, {}).get(name, selected[name]['entry']['sourceVersion'])
    return changed


@contextmanager
def borrowed_manifest(root, selected, mutation=False, requested=None):
    path = Path(root) / 'composer.json'
    original = path.read_bytes()
    document = json.loads(original)
    try:
        path.write_text(json.dumps(bind(document, selected), indent=2) + '\n')
        yield
    except BaseException:
        path.write_bytes(original)
        raise
    else:
        if mutation:
            changed = restore(json.loads(original), json.loads(path.read_text()), selected, requested)
            if changed == json.loads(original):
                path.write_bytes(original)
            else:
                path.write_text(json.dumps(changed, indent=2) + '\n')
        else:
            path.write_bytes(original)


def sdk_environment(selected, php, autoload, bindings=None, base=None):
    import os
    environment = dict(base or os.environ, COMPOSER_PURIFIER_PHP=php, COMPOSER_PURIFIER_AUTOLOAD=autoload, COMPOSER_POLICY='0')
    environment['COMPOSER_PURIFIER_VERSIONS'] = json.dumps({name: value['entry']['version']
                                                          for name, value in selected.items()})
    environment['COMPOSER_PURIFIER_PACKAGES'] = json.dumps([
        {'metadata': value['metadata'], 'source': value['source']} for value in selected.values()])
    if bindings:
        environment['COMPOSER_PURIFIER_BINDINGS'] = str(bindings)
    return environment


def materialize_selected(root, selected, php, autoload, bindings=None, environment=None, anchors=None):
    import subprocess
    import tempfile
    root = Path(root)
    manifest_path = root / 'composer.json'
    bound = bind(json.loads(manifest_path.read_text()), selected)
    manifest_path.write_text(json.dumps(bound, indent=2) + '\n')
    lock_path = root / 'composer.lock'
    if not lock_path.exists():
        return
    with tempfile.TemporaryDirectory(prefix='composer-frozen-') as temporary:
        frozen = Path(temporary) / 'composer.lock'
        frozen.write_bytes(lock_path.read_bytes())
        snapshot = json.loads(frozen.read_text())
        fixed = json.loads(json.dumps(bound))
        for group, field in (('packages', 'require'), ('packages-dev', 'require-dev')):
            for package in snapshot.get(group, []):
                if package['name'] not in selected and package['name'] not in fixed.get('require', {}) and package['name'] not in fixed.get('require-dev', {}):
                    fixed.setdefault(field, {})[package['name']] = '=' + package['version']
            for name in (anchors or {}).get(group, []):
                if name in selected:
                    fixed.setdefault(field, {})[name] = '=' + selected[name]['entry']['version']
        manifest_path.write_text(json.dumps(fixed, indent=2) + '\n')
        environment = sdk_environment(selected, php, autoload, bindings, environment)
        environment['COMPOSER_PURIFIER_FROZEN_LOCK'] = str(frozen)
        environment['COMPOSER_DISABLE_NETWORK'] = '1'
        subprocess.run([php, str(Path(__file__).with_name('composer_capture.php')), 'update',
                        '--no-install', '--no-audit', '--no-interaction', '--no-plugins', '--no-scripts'],
                       cwd=root, env=environment, check=True)
        manifest_path.write_text(json.dumps(bound, indent=2) + '\n')
        hydrated = json.loads(lock_path.read_text())
        hydrated['content-hash'] = manifest_hash(root, php, autoload)
        lock_path.write_text(json.dumps(hydrated, indent=2) + '\n')


def manifest_hash(root, php, autoload):
    import subprocess
    return subprocess.check_output([php, '-r',
        'require $argv[1]; echo Composer\\Package\\Locker::getContentHash(file_get_contents($argv[2]));',
        autoload, str(Path(root) / 'composer.json')], text=True)


def check_manifest(root, php, autoload):
    native = json.loads((Path(root) / 'composer.lock').read_text())
    if native.get('content-hash') != manifest_hash(root, php, autoload):
        raise ValueError('composer.json changed; run composer-purifier lock')


def materialize(root, views, php, autoload):
    check_manifest(root, php, autoload)
    if isinstance(views, list):
        views = {'repositories': views}
    materialize_selected(root, packages(views['repositories']), php, autoload, anchors=views.get('roots'))


def binding_key(package):
    source, dist = package.get('source', {}), package.get('dist', {})
    return json.dumps([package['name'], package['version'], source.get('url'), source.get('reference'),
                       dist.get('url'), dist.get('reference')], separators=(',', ':'))


def portable_lock(root, selected, bindings, php, autoload):
    import subprocess
    root = Path(root)
    lock_path = root / 'composer.lock'
    native = json.loads(lock_path.read_text())
    original = json.loads(Path(bindings).read_text()) if bindings and Path(bindings).exists() else {}
    used = {}
    for field in ('packages', 'packages-dev'):
        used[field] = [package['name'] for package in native.get(field, []) if package['name'] in selected]
        retained = []
        for package in native.get(field, []):
            if package['name'] in selected:
                continue
            for name, requirement in original.get(binding_key(package), {}).items():
                if name in selected and name in package.get('require', {}):
                    package['require'][name] = requirement
            retained.append(package)
        native[field] = retained
    native['content-hash'] = manifest_hash(root, php, autoload)
    lock_path.write_text(json.dumps(native, indent=2) + '\n')
    return used


if __name__ == '__main__':
    import sys
    materialize(sys.argv[1], json.loads(Path(sys.argv[2]).read_text()), *sys.argv[3:])
