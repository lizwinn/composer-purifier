#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The stand-in for composer-purifier-hash-checkout that locks tests/fixtures/vcs,
# whose repositories are unreachable. It prints the same hash for every
# checkout. The checks build that fixture with stand-ins for the nixpkgs
# fetchers, which check their arguments and do not check the hash.
echo "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
