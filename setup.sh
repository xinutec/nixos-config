#!/usr/bin/env bash
# `pipefail` is a bash option — it is undefined in POSIX sh. NixOS happens to point
# /bin/sh at bash, so `#!/bin/sh` worked by luck; declare the shell we actually use.

set -euxo pipefail

HOST=$(hostname)
PASSWD=$(mkpasswd -m sha-512)

sed -e "s!@HOST@!$HOST!;s!@PASSWD@!$PASSWD!" configuration.nix.dist > configuration.nix
