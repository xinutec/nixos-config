#!/bin/sh

set -eux

HOST=$(hostname)
PASSWD=$(mkpasswd -m sha-512)

sed -e "s!@HOST@!$HOST!;s!@PASSWD@!$PASSWD!" configuration.nix.dist > configuration.nix
