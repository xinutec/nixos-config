# agenix — fleet secrets

Secrets the NixOS hosts need at activation, encrypted into this repo
with [agenix](https://github.com/ryantm/agenix) and decrypted per-host
at activation. agenix is pinned in `base-configuration.nix` (a
`fetchTarball` of tag 0.15.0).

## How it works

Each `*.age` file is an [age](https://github.com/FiloSottile/age)-encrypted
secret. `secrets.nix` is the recipient map: per file, the public keys
allowed to decrypt it —

- **each host's SSH host key** (`ssh-ed25519 …`) — the identity agenix
  uses on that host to decrypt at activation;
- **the fleet admin age key** — a master key, held off-fleet by the
  operator, that is a recipient of *every* secret and so can decrypt
  and re-encrypt all of them.

At activation agenix decrypts each secret the host is a recipient of —
to `/run/agenix/<name>` (a ramfs), or, where `symlink = false`, to a
fixed path. The NixOS modules reference those paths.

## The secrets

| File | Recipients | Consumed by |
|---|---|---|
| `grafana-agent-password.age` | all hosts + admin | alloy → Grafana/Mimir, `grafana-alloy.nix` |
| `restic-password.age` | odin + admin | restic backup / check / drill, `machines/odin/backups.nix` |
| `wireguard-<host>.age` | that host + admin | the host's `wg0` private key, `base-configuration.nix` |
| `root-ssh-ed25519.age` | all hosts + admin | `/root/.ssh/id_ed25519`, inter-host root SSH |
| `root-ssh-rsa.age` | all hosts + admin | `/root/.ssh/id_rsa`, inter-host root SSH (legacy) |

## Editing or adding a secret

The agenix CLI reads `secrets.nix`, so run it from this directory:

```
nix-shell -p agenix --run 'agenix -e restic-password.age'
```

This opens the decrypted secret in `$EDITOR`; saving re-encrypts it.
To add a new secret, first add a `"<name>.age".publicKeys = …` entry
to `secrets.nix`, then `agenix -e <name>.age`. Editing needs an
identity that can decrypt the file — a recipient host key, or the
admin key via `-i <admin-key>`.

## Rebuilding a host from scratch

agenix can only decrypt a secret for a host that is one of its
recipients. A reinstalled host has a **new SSH host key**, so it is not
yet a recipient of anything — the secrets must be re-keyed to its new
key before it can activate this configuration.

1. Install NixOS on the new hardware. sshd generates host keys on
   first boot; the host is reachable over its public IP throughout.
2. Read the new host key on it:
   `cat /etc/ssh/ssh_host_ed25519_key.pub`
3. On the admin machine (which holds the admin age key), edit
   `agenix/secrets.nix` — replace that host's old `ssh-ed25519 …` line
   with the new key.
4. Re-encrypt every secret to the updated recipients:
   `cd agenix && nix-shell -p agenix --run 'agenix --rekey -i ~/.config/age/xinutec-fleet-admin.txt'`
5. Commit and push `secrets.nix` and the re-keyed `*.age` files.
6. On the new host, put this repo at `/etc/nixos`, then
   `nixos-rebuild switch` — agenix decrypts with the new host key.

The admin key is what makes step 4 possible: it is a recipient of
every secret, so it alone can re-key all of them. Without it, a secret
can only be re-keyed from a host that can still decrypt it. If several
hosts are rebuilt at once, update all their keys in `secrets.nix` and
run `agenix --rekey` once.

## After a rebuild — known_hosts

`/root/.ssh/known_hosts` is **not** an agenix secret (it holds host
*public* keys) and starts empty on a fresh install. Inter-host root SSH
— the backup rsyncs and the restore drill — uses strict host-key
checking, so the rebuilt host, and any host connecting to it, needs the
relevant entries in `known_hosts`. Populate it (e.g. with `ssh-keyscan`)
during bring-up.
