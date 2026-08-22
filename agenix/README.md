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
| `root-ssh-fleet.age` | all hosts + admin | `/root/.ssh/id_fleet`, inter-host root SSH |
| `root-ssh-ed25519.age` | all hosts + admin | **nothing, since 2026-08-22** — see below |
| `root-ssh-rsa.age` | all hosts + admin | **nothing, since 2026-08-22** — see below |
| `home-ingest-token.age` | geb + admin | the Govee pusher's bearer token, `machines/geb/configuration.nix` |
| `hc-ping-md.age` | amun + admin | RAID heartbeat check ID, `machines/amun/md-healthcheck.nix` |
| `hc-ping-backup.age` | odin + admin | backup check ID, `machines/odin/backups.nix` |
| `hc-ping-drill.age` | odin + admin | restore-drill check ID, `machines/odin/drill/drill-run.sh` |

### The two `root-ssh-{ed25519,rsa}` secrets consume nothing

They were `/root/.ssh/id_{ed25519,rsa}` on every host until 2026-08-22, and #1049
is what they were. Their public halves are `pippijn@xinutec.org` — the key
Pippijn logs in with — so the fleet authenticated to itself using a personal
identity, and the private half of that identity sat on four machines, two of them
internet-facing. Root on any host was root on every host, and on him.

`root-ssh-fleet.age` replaces them: generated for the job, in no personal key
list, so it can be rotated or confined without asking what else it opens.

They are kept rather than deleted for one reason and it is not sentiment. This
repository is **public**, so their ciphertext is in the git history permanently
and removing the files buys no secrecy at all; what deletion could cost is
Pippijn's only copy of a key he still uses personally. The follow-up that would
actually help is rotating that personal key, which is his to make.

⚠ Anything restored from a backup predating 2026-08-22 brings `id_rsa` and
`id_ed25519` back to `/root/.ssh` — and both names are on OpenSSH's default
identity list, so they would silently resume carrying inter-host logins. Check
for them after any restore.

### Why a check ID is a secret

A healthchecks.io check ID is a **capability, not a name**. Anyone holding
one can `GET` the URL to mark the check *up* — silencing the dead-man's
switch — or `GET …/fail` to raise a false alarm. It discloses nothing, so
it reads like an identifier; but these three checks are precisely what
notices when the backup and the restore drill go quiet, and a leaked ID
turns *"tell me when this stops"* into *"this never stops"*. A crawler
that merely followed the URL would report a failed backup as successful.

Only the **ID** is encrypted. Each module still spells out the base URL
`https://hc-ping.com`, because where a host checks in is documentation.

These are read at **run time** from `/run/agenix/…`, never with
`builtins.readFile`: agenix decrypts during activation, which happens
*after* evaluation, so an eval-time read would fail on a fresh boot.

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

### ⚠ `--rekey` can do nothing and still look like it worked

Observed onboarding geb, 2026-08-10. `agenix --rekey` prints
`rekeying <file>...` for every secret and then, for each one,
`<file> wasn't changed, skipping re-encryption` — and skips it. It
decides by whether the PLAINTEXT changed, which during a re-key is
exactly what does not change. Adding a host to `publicKeys` therefore
had no effect on any of the three shared secrets, while the output read
as success. The failure surfaces later and elsewhere: the new host's
first `nixos-rebuild switch` fails at activation, on a repo that was
already committed and pushed.

**Verify the recipients, not the message.** An age file lists one `->`
stanza per recipient in its header, so the count is readable directly —
the files are binary, hence `grep -a`:

```
for f in *.age; do printf '%-28s %s\n' "$f" "$(head -c 4000 "$f" | grep -ac '^-> ')"; done
```

`allHosts` secrets should show one stanza per host plus one for the
admin key. If a re-key was skipped the count is simply unchanged.

To actually re-key, decrypt and re-encrypt explicitly:

```
age -d -i ~/.config/age/xinutec-fleet-admin.txt <file>.age > /tmp/plain
age -r "<host1 key>" … -r "<admin key>" -o <file>.age /tmp/plain
```

Then confirm two things empirically rather than by inspection: that the
NEW host can decrypt it with `/etc/ssh/ssh_host_ed25519_key`, and that
an EXISTING host still can. Re-encrypting from scratch is also how a
host gets silently locked out.

## After a rebuild — known_hosts

`/root/.ssh/known_hosts` is **not** an agenix secret (it holds host
*public* keys) and starts empty on a fresh install. Inter-host root SSH
— the backup rsyncs and the restore drill — uses strict host-key
checking, so the rebuilt host, and any host connecting to it, needs the
relevant entries in `known_hosts`. Populate it (e.g. with `ssh-keyscan`)
during bring-up.
