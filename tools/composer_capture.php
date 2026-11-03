<?php
// SPDX-License-Identifier: MIT
// Run the native application, binding package requirements before its SAT solve.
declare(strict_types=1);

require getenv('COMPOSER_PURIFIER_AUTOLOAD');

final class NixProvidedRepository extends Composer\Repository\ArrayRepository
{
    public function loadPackages(array $packageNameMap, array $acceptableStabilities, array $stabilityFlags, array $alreadyLoaded = [])
    {
        $packages = [];
        $found = [];
        foreach ($packageNameMap as $name => $constraint) {
            foreach ($this->getPackages() as $package) {
                $matches = $package->getName() === $name;
                foreach (array_merge($package->getProvides(), $package->getReplaces()) as $link) {
                    if ($link->getTarget() === $name && (!$constraint || $link->getConstraint()->matches($constraint))) {
                        $matches = true;
                    }
                }
                if ($matches) {
                    $found[$name] = true;
                    if (!isset($alreadyLoaded[$package->getName()][$package->getVersion()])) {
                        $packages[spl_object_id($package)] = $package;
                    }
                }
            }
        }
        return ['namesFound' => array_keys($found), 'packages' => $packages];
    }
}

final class FrozenComposerRepository extends Composer\Repository\ArrayRepository
{
    public function loadPackages(array $packageNameMap, array $acceptableStabilities, array $stabilityFlags, array $alreadyLoaded = [])
    {
        $result = parent::loadPackages($packageNameMap, $acceptableStabilities, $stabilityFlags, $alreadyLoaded);
        foreach ($packageNameMap as $name => $constraint) {
            foreach ($this->getPackages() as $package) {
                foreach (array_merge($package->getProvides(), $package->getReplaces()) as $link) {
                    if ($link->getTarget() === $name && (!$constraint || $link->getConstraint()->matches($constraint)) &&
                        !isset($alreadyLoaded[$package->getName()][$package->getVersion()])) {
                        $result['packages'][spl_object_id($package)] = $package;
                    }
                }
            }
        }
        // Every other native repository is behind this canonical repository.
        // A missing ordinary package must be locked, never looked up here.
        $result['namesFound'] = array_keys($packageNameMap);
        return $result;
    }
}

final class PurifiedComposerApplication extends Composer\Console\Application
{
    private array $attached = [];

    public function getComposer(bool $required = true, ?bool $disablePlugins = null, ?bool $disableScripts = null): ?Composer\Composer
    {
        $composer = parent::getComposer($required, $disablePlugins, $disableScripts);
        if ($composer !== null && !isset($this->attached[spl_object_id($composer)])) {
            $this->attached[spl_object_id($composer)] = $composer;
            $versions = json_decode(getenv('COMPOSER_PURIFIER_VERSIONS') ?: '{}', true, 512, JSON_THROW_ON_ERROR);
            $supplied = json_decode(getenv('COMPOSER_PURIFIER_PACKAGES') ?: '[]', true, 512, JSON_THROW_ON_ERROR);
            $parser = new Composer\Package\Version\VersionParser();
            $loader = new Composer\Package\Loader\ArrayLoader($parser);
            if ($frozen = getenv('COMPOSER_PURIFIER_FROZEN_LOCK')) {
                $lock = json_decode(file_get_contents($frozen), true, 512, JSON_THROW_ON_ERROR);
                $ordinary = [];
                foreach (array_merge($lock['packages'] ?? [], $lock['packages-dev'] ?? []) as $metadata) {
                    if (!isset($versions[$metadata['name']])) {
                        $ordinary[] = $loader->load($metadata);
                    }
                }
                $composer->getRepositoryManager()->prependRepository(new FrozenComposerRepository($ordinary));
            }
            $providedPackages = [];
            foreach ($supplied as $entry) {
                $package = $loader->load($entry['metadata']);
                $package->setDistType('path');
                $package->setDistUrl($entry['source']);
                $package->setDistReference($entry['metadata']['version']);
                $package->setTransportOptions(['symlink' => false]);
                $providedPackages[] = $package;
            }
            $composer->getRepositoryManager()->prependRepository(new NixProvidedRepository($providedPackages));
            $bindRoot = static function () use ($composer, $versions, $parser): void {
                $root = $composer->getPackage();
                foreach (['Requires', 'DevRequires'] as $kind) {
                    $getter = 'get' . $kind;
                    $setter = 'set' . $kind;
                    $links = $root->$getter();
                    foreach ($links as $name => $link) {
                        if (isset($versions[$name])) {
                            $constraint = '=' . $versions[$name];
                            $links[$name] = new Composer\Package\Link($root->getName(), $name,
                                $parser->parseConstraints($constraint), $link->getDescription(), $constraint);
                        }
                    }
                    $root->$setter($links);
                }
            };
            $composer->getEventDispatcher()->addListener(Composer\Script\ScriptEvents::PRE_UPDATE_CMD, $bindRoot, -10000);
            $composer->getEventDispatcher()->addListener(Composer\Script\ScriptEvents::PRE_INSTALL_CMD, $bindRoot, -10000);
            $composer->getEventDispatcher()->addListener(Composer\Plugin\PluginEvents::PRE_POOL_CREATE,
                static function (Composer\Plugin\PrePoolCreateEvent $event) use ($versions, $supplied, $parser): void {
                    $packages = $event->getPackages();
                    $present = [];
                    foreach ($packages as $package) {
                        $present[$package->getName() . '@' . $package->getPrettyVersion()] = true;
                    }
                    $loader = new Composer\Package\Loader\ArrayLoader($parser);
                    foreach ($supplied as $entry) {
                        $metadata = $entry['metadata'];
                        if (!isset($present[$metadata['name'] . '@' . $metadata['version']])) {
                            $package = $loader->load($metadata);
                            $package->setDistType('path');
                            $package->setDistUrl($entry['source']);
                            $package->setDistReference($metadata['version']);
                            $package->setTransportOptions(['symlink' => false]);
                            $packages[] = $package;
                        }
                    }
                    foreach ($packages as $package) {
                        $requires = $package->getRequires();
                        $bindingsPath = getenv('COMPOSER_PURIFIER_BINDINGS');
                        $bindings = $bindingsPath && is_file($bindingsPath) ?
                            json_decode(file_get_contents($bindingsPath), true, 512, JSON_THROW_ON_ERROR) : [];
                        $key = json_encode([$package->getName(), $package->getPrettyVersion(),
                            $package->getSourceUrl(), $package->getSourceReference(),
                            $package->getDistUrl(), $package->getDistReference()], JSON_UNESCAPED_SLASHES);
                        foreach ($requires as $name => $link) {
                            if (isset($versions[$name])) {
                                $constraint = '=' . $versions[$name];
                                if ($link->getPrettyConstraint() !== $constraint || !isset($bindings[$key][$name])) {
                                    $bindings[$key][$name] = $link->getPrettyConstraint();
                                }
                                $requires[$name] = new Composer\Package\Link($package->getName(), $name,
                                    $parser->parseConstraints($constraint), 'requires', $constraint);
                            }
                        }
                        $package->setRequires($requires);
                        if ($bindingsPath) {
                            file_put_contents($bindingsPath, json_encode($bindings, JSON_THROW_ON_ERROR));
                        }
                    }
                    $event->setPackages($packages);
                });
        }
        return $composer;
    }
}

exit((new PurifiedComposerApplication())->run());
