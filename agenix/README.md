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
| `home-ingest-token.age` | geb + admin | the Govee pusher's bearer token, `machines/geb/configuration.nix` |
| `hc-ping-md.age` | amun + admin | RAID heartbeat check ID, `machines/amun/md-healthcheck.nix` |
| `hc-ping-backup.age` | odin + admin | backup check ID, `machines/odin/backups.nix` |
| `hc-ping-drill.age` | odin + admin | restore-drill check ID, `machines/odin/drill/drill-run.sh` |
| `hc-ping-integrity.age` | odin + admin | integrity check ID, `machines/odin/backups.nix` → `plan-settings.nix` |
| `geb-restic-password.age` | odin + admin | **nothing on any host — ESCROW, see below** |
| `offsite-restic-password.age` | odin + admin | **nothing on any host — ESCROW, see below** |

### The two escrowed restic passwords consume nothing ON PURPOSE

`geb-restic-password` and `offsite-restic-password` are **not deployed to any
host** and will not appear in `/run/agenix`. They are the Mac's, and the Mac is
where they are used; these copies exist so the passwords survive the house.

⚠ **A secret consuming nothing is exactly what the retired `root-ssh-*` pair
looked like, and these are the opposite — do not "tidy" them away.** The
distinction is in `secrets.nix`: their live copies sit in two in-house places,
and so does the admin key, so it is **odin holding a copy — in a datacenter, not
in the house — that makes this a real third copy** rather than a second one in
the same building.

### The two `root-ssh-{ed25519,rsa}` secrets are GONE

They were `/root/.ssh/id_{ed25519,rsa}` on every host until 2026-08-22, and #1049
is what they were. Their public halves were `pippijn@xinutec.org` — the key
Pippijn logs in with — so the fleet authenticated to itself using a personal
identity, and the private half of that identity sat on four machines, two of them
internet-facing. Root on any host was root on every host, and on him.

`root-ssh-fleet.age` replaced them: generated for the job, in no personal key
list, so it can be rotated or confined without asking what else it opens.

**Undeployed 2026-08-22, and the `.age` files DELETED 2026-08-23.** An earlier
version of this file argued for keeping them, on the reasoning that deletion
could cost Pippijn's only copy of a key he still used personally. Two things
retired that argument:

* **He did not use it.** `Accepted publickey for pippijn` with either
  fingerprint, over the 90 days to 2026-08-23: 0 on isis, 0 on amun, 0 on odin.
  The keypair was retired from the `pippijn` list too, so it now opens nothing
  anywhere.
* **Nothing is lost that was not already lost.** This repository is **public**,
  so the ciphertext is in the git history permanently — deleting the files buys
  no secrecy, and equally destroys no copy. The private half is still recoverable
  from history with the admin key if it is ever wanted.

⚠ **The exposure that mattered was not the file, it was the authorization.** The
published ciphertext was decryptable by anyone holding one of the four host keys
— i.e. by root on amun or isis, the internet-facing pair — and that key was still
authorized on `github.com/pippijn`, which can push to this repository, which every
host rebuilds from. That GitHub key was removed the same day. What makes the
published ciphertext worthless is that the keypair opens nothing, not that the
files are gone.

⚠ **agenix writes at activation and NEVER deletes.** Dropping the `age.secrets`
entries left `/root/.ssh/id_{rsa,ed25519}` on disk; they were moved aside by hand
on all four hosts as `*.removed-20260822`. A host restored from a backup older
than that brings them back, and both names are on OpenSSH's default identity
list — so they would silently resume carrying inter-host root logins.
`fleet_health.py`'s agenix check asserts their ABSENCE for exactly this reason.

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

   ⚠ **A NEW host has only the `nixos` channel, and this repo needs two.**
   `base-configuration.nix` imports `<home-manager/nixos>`, so without it
   `nixos-rebuild` fails at evaluation with `file 'home-manager/nixos' was
   not found in the Nix search path` — which names the search path rather
   than the missing channel, and arrives long after the secrets work looks
   finished. Add it to match the rest of the fleet:

       nix-channel --add https://github.com/nix-community/home-manager/archive/release-26.05.tar.gz home-manager
       nix-channel --update

   A REINSTALLED host needs this too: channels are machine state, so a fresh
   disk has none of them.
2. Read the new host key on it:
   `cat /etc/ssh/ssh_host_ed25519_key.pub`
3. On the admin machine (which holds the admin age key), edit
   `agenix/secrets.nix` — replace that host's old `ssh-ed25519 …` line
   with the new key.
4. Re-encrypt every secret to the updated recipients:
   `cd agenix && nix-shell -p agenix --run 'agenix --rekey -i ~/.config/age/xinutec-fleet-admin.txt'`
5. Commit and push `secrets.nix` and the re-keyed `*.age` files.
6. On the new host, put this repo at `/etc/nixos`, then build and
   activate — agenix decrypts with the new host key. Two files a host has
   that a clean checkout does not, both gitignored, must be placed first:
   `configuration.nix` (from `configuration.nix.dist`, via `setup.sh`) and
   the machine's `hardware-configuration.nix`, copied to the repo ROOT
   because `base-configuration.nix` imports it relative to itself.

   ⚠ **`boot` then reboot, not `switch`** — Pippijn's rule for every host
   except amun, which cannot be rebooted freely. Keep the pre-existing
   `/etc/nixos` as `/etc/nixos.bootstrap`: if the fleet config will not
   activate, that is what the machine is still running and what it goes
   back to.

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
