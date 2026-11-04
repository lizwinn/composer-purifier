#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native SDK checks for hash versions and transitive source bindings."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import unittest

sys.path.insert(0, os.environ.get('COMPOSER_REPOSITORY_TOOLS', str(Path(__file__).resolve().parents[1] / 'tools')))
from composer_inputs import borrowed_manifest, materialize_selected, portable_lock
from composer_repository import version

composer, php, autoload = sys.argv[1:4]
sys.argv = sys.argv[:1]


def run(*arguments, cwd=None, env=None):
    return subprocess.check_output([str(argument) for argument in arguments], cwd=cwd, env=env, text=True)


class ComposerRepository(unittest.TestCase):
    def test_full_hash_versions_use_native_stable_comparison(self):
        first = version('f' * 63 + 'e')
        second = version('f' * 64)
        result = run(php, '-r', '''require $argv[1];
          $parser = new Composer\\Semver\\VersionParser();
          echo json_encode([$parser->parseStability($argv[2]),
            Composer\\Semver\\Semver::satisfies($argv[2], '=' . $argv[3])]);''', autoload, first, second)
        self.assertEqual(json.loads(result), ['stable', False])

    def test_native_hook_binds_unchanged_upstream_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / 'repository'
            repository.mkdir()
            supplied_version = version(hashlib.sha256(b'provided-lib').hexdigest())
            environment = dict(os.environ, COMPOSER_HOME=str(root / 'home'),
                COMPOSER_CACHE_DIR=str(root / 'cache'), COMPOSER_DISABLE_NETWORK='1',
                COMPOSER_POLICY='0', COMPOSER_ALLOW_SUPERUSER='1')
            records = {}
            for name in ('lib', 'parent'):
                source = root / name
                (source / 'src').mkdir(parents=True)
                metadata = {'name': 'proof/' + name, 'version': supplied_version if name == 'lib' else '1.0.0',
                    'license': 'MIT', 'autoload': {'psr-4': {'Proof\\' + name.capitalize() + '\\': 'src/'}}}
                if name == 'parent':
                    metadata['require'] = {'proof/lib': '99'}
                (source / 'composer.json').write_text(json.dumps(metadata))
                expression = '42' if name == 'lib' else '\\Proof\\Lib\\Answer::value()'
                (source / 'src/Answer.php').write_text('<?php namespace Proof\\' + name.capitalize() +
                    '; class Answer { public static function value():int { return ' + expression + '; }}')
                run(composer, 'archive', '--no-plugins', '--no-scripts', '--format=zip',
                    '--dir=' + str(repository), '--file=' + name, cwd=source, env=environment)
                archive = repository / (name + '.zip')
                metadata['dist'] = {'type': 'zip', 'url': archive.as_uri(),
                                    'shasum': hashlib.sha1(archive.read_bytes()).hexdigest()}
                records[metadata['name']] = {metadata['version']: metadata}
            records['proof/meta'] = {'1.0.0': {'name': 'proof/meta', 'version': '1.0.0',
                'type': 'metapackage', 'license': 'MIT', 'require': {'proof/parent': '1'}}}
            (repository / 'packages.json').write_text(json.dumps({'packages': records}))
            upstream = (repository / 'parent.zip').read_bytes()
            consumer = root / 'consumer'
            consumer.mkdir()
            original = json.dumps({'name': 'proof/consumer', 'require': {'proof/meta': '1'},
                'repositories': [{'type': 'composer', 'url': repository.as_uri()}, {'packagist.org': False}],
                'scripts': {'proof': '@php -r \'require "vendor/autoload.php"; echo Proof\\Parent\\Answer::value();\''}})
            (consumer / 'composer.json').write_text(original)
            selected = {'proof/lib': {'entry': {'version': supplied_version, 'sourceVersion': '1.0.0'},
                'metadata': json.loads((root / 'lib/composer.json').read_text()), 'source': str(root / 'lib')}}
            environment.update(COMPOSER_PURIFIER_AUTOLOAD=autoload,
                COMPOSER_PURIFIER_VERSIONS=json.dumps({'proof/lib': supplied_version}),
                COMPOSER_PURIFIER_PACKAGES=json.dumps([{'metadata': selected['proof/lib']['metadata'],
                                                       'source': selected['proof/lib']['source']}]),
                COMPOSER_PURIFIER_BINDINGS=str(root / 'bindings.json'))
            with borrowed_manifest(consumer, selected):
                run(php, str(Path(__file__).resolve().parents[1] / 'tools/composer_capture.php')
                    if 'COMPOSER_REPOSITORY_TOOLS' not in os.environ else
                    str(Path(os.environ['COMPOSER_REPOSITORY_TOOLS']) / 'composer_capture.php'),
                    'update', '--no-plugins', '--no-scripts', '--no-audit', '--no-interaction',
                    cwd=consumer, env=environment)
                self.assertEqual(run(composer, 'run-script', 'proof', cwd=consumer, env=environment), '42')
                scripts = Path(os.environ.get('COMPOSER_REPOSITORY_SCRIPTS', str(Path(__file__).resolve().parents[1] / 'src')))
                run(php, scripts / 'lock.php', autoload, '--lockfile', root / 'hashes.json',
                    cwd=consumer, env=environment)
                captured = json.loads((root / 'hashes.json').read_text())
                self.assertEqual(captured['dists'], {})
                self.assertEqual(captured['sources'], {})
            self.assertEqual((consumer / 'composer.json').read_text(), original)
            self.assertEqual((repository / 'parent.zip').read_bytes(), upstream)
            lock = json.loads((consumer / 'composer.lock').read_text())
            packages = {package['name']: package for package in lock['packages']}
            self.assertEqual(packages['proof/parent']['require']['proof/lib'], '=' + supplied_version)
            self.assertEqual(packages['proof/lib']['dist']['type'], 'path')
            self.assertFalse(packages['proof/lib']['dist'].get('shasum'))
            portable_lock(consumer, selected, root / 'bindings.json', php, autoload)
            saved = (consumer / 'composer.lock').read_bytes()
            portable = json.loads(saved)
            self.assertEqual([package['name'] for package in portable['packages']], ['proof/meta', 'proof/parent'])
            parent, = [package for package in portable['packages'] if package['name'] == 'proof/parent']
            self.assertEqual(parent['require']['proof/lib'], '99')
            # A different target-system projection has different generated IDs.
            # The checked-in native lock must remain identical across them.
            other = root / 'other-lib'
            shutil.copytree(root / 'lib', other)
            different = version(hashlib.sha256(b'another-target-system').hexdigest())
            metadata = json.loads((other / 'composer.json').read_text())
            metadata['version'] = different
            (other / 'composer.json').write_text(json.dumps(metadata))
            alternate = {'proof/lib': {'entry': {'version': different, 'sourceVersion': '1.0.0'},
                                      'metadata': metadata, 'source': str(other)}}
            materialize_selected(consumer, alternate, php, autoload, root / 'other-bindings.json', environment)
            hydrated = json.loads((consumer / 'composer.lock').read_text())
            provided, = [package for package in hydrated['packages'] if package['name'] == 'proof/lib']
            self.assertEqual(provided['version'], different)
            run(composer, 'install', '--no-plugins', '--no-scripts', '--no-interaction', cwd=consumer, env=environment)
            self.assertEqual(run(composer, 'run-script', 'proof', cwd=consumer, env=environment), '42')
            portable_lock(consumer, alternate, root / 'other-bindings.json', php, autoload)
            self.assertEqual((consumer / 'composer.lock').read_bytes(), saved)


unittest.main()
