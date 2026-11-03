# SPDX-License-Identifier: MIT
{
  pkgs,
  project,
  alternate ? null,
}:
let
  repository = project.projections.composer;
  rebuilt = repository.overrideAttrs (_: {
    name = "composer-repository-rebuilt";
  });
  php = project.php;
in
pkgs.runCommand "composer-projected-ordinary-consumer"
  {
    nativeBuildInputs = [
      pkgs.python3
      php
      php.packages.composer
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    export COMPOSER_HOME="$TMPDIR/composer-home"
    export COMPOSER_CACHE_DIR="$TMPDIR/cache"
    export COMPOSER_DISABLE_NETWORK=1
    export COMPOSER_POLICY=0
    export COMPOSER_ALLOW_SUPERUSER=1
    diff -r ${repository} ${rebuilt}
    ${pkgs.lib.optionalString (alternate != null) ''
      diff -r ${repository} ${alternate.projections.composer}
    ''}
    python3 - ${repository} <<'PY'
    import json
    import pathlib
    import sys
    repository = pathlib.Path(sys.argv[1])
    catalog = json.loads((repository / '.catalog').read_text())
    root, = catalog['roots']
    pathlib.Path('composer.json').write_text(json.dumps({
        'name': 'proof/ordinary',
        'require': {root['name']: '=' + root['version']},
        'repositories': [{'type': 'artifact', 'url': str(repository)}, {'packagist.org': False}],
    }))
    PY
    composer update --no-interaction --no-progress --no-audit --no-plugins --no-scripts
    php -r 'require "vendor/autoload.php"; if (!class_exists("Monolog\\Logger")) exit(1); echo Fixture\Greeting::text();' > actual
    test "$(cat actual)" = 'hello from composer-purifier'
    touch "$out"
  ''
