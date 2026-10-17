# The iSH fallback tunnel

This is the bootstrap and the rollback for everything else in this repo.

```
client -> HTTP proxy (privoxy :8118) -> SOCKS5 (ssh -D :1080) -> iPhone (iSH :2222) -> cellular
```

It is fragile, and deliberately kept that way rather than fixed: iSH runs an
emulated x86 userspace, so its `sshd` burns CPU and makes the phone hot, it gets
suspended when the screen locks, and its `sshd` serves exactly one connection at
a time. Every one of those is a reason the native app in this repo exists.

What it still does better than anything here: **it needs nothing installed on
the iPhone.** No signing, no seven-day profile, no SideStore, no Tailscale
entitlement. When it is the only thing keeping this laptop online, that is worth
a great deal.

## ⚠️ This machine has no other uplink

Stopping this tunnel takes the laptop offline — including any agent session,
CI watch, or package download in flight. That is correct behaviour, not a bug.

## Usage

```sh
./ish-tunnel.sh start     # idempotent; adopts an already-running tunnel
./ish-tunnel.sh status    # health check, prints a real egress IP
./ish-tunnel.sh stop      # tear down. laptop goes offline.
./ish-tunnel.sh env       # print the exports
./ish-tunnel.sh run <cmd> # run a command with the proxy env injected
./ish-tunnel.sh direct <cmd>   # run with ALL proxy vars cleared
```

### Running things through it

```sh
./ish-tunnel.sh run curl https://api.ipify.org
./ish-tunnel.sh run gh run list
./ish-tunnel.sh run git push
```

Or for a whole shell session:

```sh
eval "$(./ish-tunnel.sh env)"
```

## Why two different proxy variables

`proxy_env()` exports six variables covering two client families that do not
speak the same protocol:

| Variable | Value | For |
| --- | --- | --- |
| `all_proxy` / `ALL_PROXY` | `socks5h://127.0.0.1:1080` | curl and SOCKS-aware tools |
| `http_proxy` / `HTTPS_PROXY` | `http://127.0.0.1:8118` | Go binaries — `gh`, `go` |

Go's `net/http` honours `HTTPS_PROXY` and has never heard of `ALL_PROXY`. Set
only the SOCKS variable and `gh` reports `error connecting to api.github.com`,
then `gh auth status` declares your token invalid. Both messages are false, and
chasing them costs an afternoon. privoxy is the bridge that makes one variable
serve both families.

`socks5h` rather than `socks5` matters too: it makes the **phone** resolve
hostnames, which keeps DNS inside the tunnel instead of leaking to the LAN.

## The `direct` subcommand

`direct` clears every proxy variable in both cases. That exists because of a
real false pass: with both `all_proxy` and `HTTP_PROXY` set in the same shell,
unsetting only the lowercase ones leaves the uppercase ones live, and a
supposedly-direct request silently goes out through this tunnel anyway and
reports success.

```sh
./ish-tunnel.sh direct curl https://api.ipify.org   # fails: no other uplink
```

If that ever *succeeds*, the laptop has gained an uplink you did not know about —
worth knowing before you trust any other measurement.

## Known gotcha: iSH serves one connection

`sshd` inside iSH accepts a single session and **refuses new ones** while it is
live, so `start` reports:

```
ERROR: nothing listening on 10.42.0.10:2222.
```

…even though the phone is up and reachable. The fix is always the same: open
iSH on the iPhone and confirm its `sshd` is running. iOS also suspends it when
the screen locks, which has the same symptom.

## Configuration

Override via environment if the phone's address changes:

| Variable | Default |
| --- | --- |
| `ISH_PHONE_IP` | `10.42.0.10` |
| `ISH_SSH_PORT` | `2222` |
| `ISH_SOCKS_PORT` | `1080` |
| `ISH_HTTP_PORT` | `8118` |
| `ISH_SSH_KEY_ARGS` | keepalive + relaxed host key checking |

State lives in `$XDG_RUNTIME_DIR/ish-tunnel/` (`ssh.log`, `ssh.pid`).

## When to use which

| Situation | Use |
| --- | --- |
| Bootstrapping or rolling back | this |
| Laptop has no internet, tethering through the phone | this, or the native app once proven |
| Testing the native app before trusting it | this as the rollback |
| Laptop has its own internet, just want to route via the phone | Tailscale — see [../docs/why-not-tailscale.md](../docs/why-not-tailscale.md) |
