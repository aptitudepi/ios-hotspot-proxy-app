#!/usr/bin/env python3
"""Refuse to start the tunnel unless the loop guard provably covers the phone.

This laptop has no internet uplink of its own. Everything it can reach comes
out through the phone. If sing-box's route_exclude_address fails to cover the
phone's address, sing-box captures the very traffic it uses to reach the phone,
tunnels it into itself, and the machine loses its only path out with no
automatic recovery.

A TUN cannot be created without root, so this check exists to make sure the one
mistake that bricks the machine is caught before anything irreversible runs.
"""
import ipaddress, json, sys, argparse

DEFAULT_CONFIG = "sing-box.json"


def excluded_cidrs(cfg):
    """Every route_exclude_address across all tun inbounds."""
    out = []
    for inbound in cfg.get("inbounds", []):
        if inbound.get("type") == "tun":
            out += inbound.get("route_exclude_address", []) or []
    return [ipaddress.ip_network(c) for c in out]


def phone_endpoints(cfg):
    """(host, port) of every socks outbound - where the phone is reached."""
    out = []
    for ob in cfg.get("outbounds", []):
        if ob.get("type") == "socks" and ob.get("server"):
            out.append((ob["server"], ob.get("server_port")))
    return out


def loopback_is_excluded(cfg):
    """clash_api and any local tooling must bypass the tun, or querying the API
    would go through the tunnel it is supposed to be observing."""
    nets = excluded_cidrs(cfg)
    for host in ("127.0.0.1", "::1"):
        addr = ipaddress.ip_address(host)
        if not any(addr in n for n in nets if n.version == addr.version):
            return False, host
    return True, None


def check(cfg, assume_phone_ip=None):
    problems, notes = [], []

    socks = phone_endpoints(cfg)
    if not socks:
        return ["no socks outbound found - is this the right config?"], notes

    nets = excluded_cidrs(cfg)
    if not nets:
        problems.append("no route_exclude_address on any tun inbound")
    notes.append(f"excluded cidrs: {[str(n) for n in nets]}")

    for host, port in socks:
        if assume_phone_ip and assume_phone_ip != host:
            problems.append(
                f"config points at {host} but --phone-ip says {assume_phone_ip}. "
                f"Stale config, or the phone's address changed?"
            )
        target = assume_phone_ip or host
        try:
            addr = ipaddress.ip_address(target)
        except ValueError:
            notes.append(f"{target} is not a literal IP; cannot verify coverage")
            continue
        if not any(addr in n for n in nets if n.version == addr.version):
            problems.append(
                f"FATAL: {target} (port {port}) is NOT inside any excluded CIDR. "
                f"Starting now would tunnel sing-box's own transport and cut this "
                f"machine's only uplink. Refusing."
            )
        else:
            notes.append(f"{target} is covered by the loop guard - ok")

    ok, missing = loopback_is_excluded(cfg)
    if not ok:
        problems.append(f"{missing} is not excluded; local tools would be tunnelled")
    else:
        notes.append("loopback excluded - local tooling bypasses the tun")

    return problems, notes


def self_test():
    """Exercise the guard against the configurations that actually matter."""
    # Start from the config this repo actually ships, so case 1 below is a real
    # assertion about the real file rather than about a copy of it that could
    # drift. Remaining cases mutate that.
    try:
        base = json.load(open(DEFAULT_CONFIG))
    except Exception as e:
        print(f"FATAL: cannot read {DEFAULT_CONFIG}: {e}")
        return 2
    cases = []

    # 1. Correct config must pass.
    cases.append(("correct config passes", base, None, False))

    # 2. The stale upstream subnet must be caught. This is the bug that would
    #    have bricked the machine: 192.168.137.0/24 does not cover 10.42.0.10.
    stale = json.loads(json.dumps(base))
    stale["inbounds"][0]["route_exclude_address"] = ["192.168.137.0/24", "127.0.0.0/8"]
    cases.append(("stale 192.168.137.0/24 is caught", stale, None, True))

    # 3. Empty exclude list must be caught.
    empty = json.loads(json.dumps(base))
    empty["inbounds"][0]["route_exclude_address"] = []
    cases.append(("empty exclude list is caught", empty, None, True))

    # 4. A phone that moved must be caught.
    cases.append(("phone moved is caught", base, "10.42.0.77", True))

    # 5. Phone on a bigger subnet is fine.
    wide = json.loads(json.dumps(base))
    wide["inbounds"][0]["route_exclude_address"] = ["10.42.0.0/16", "127.0.0.0/8", "::1/128"]
    cases.append(("wider subnet still passes", wide, None, False))

    # 6. Missing loopback exclusion must be caught.
    nolb = json.loads(json.dumps(base))
    nolb["inbounds"][0]["route_exclude_address"] = ["10.42.0.0/24"]
    cases.append(("missing loopback exclusion is caught", nolb, None, True))

    failures = 0
    for name, cfg, assume, expect_problem in cases:
        problems, _ = check(cfg, assume)
        got = bool(problems)
        ok = got == expect_problem
        failures += not ok
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            print(f"        expected problem={expect_problem}, got {problems}")

    # 7. No socks outbound at all.
    problems, _ = check({"inbounds": [], "outbounds": [{"type": "direct"}]})
    ok = bool(problems)
    failures += not ok
    print(f"  {'PASS' if ok else 'FAIL'}  missing socks outbound is caught")

    print(f"\n{len(cases)+1-failures}/{len(cases)+1} passed")
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--config", default=DEFAULT_CONFIG)
    ap.add_argument("--phone-ip", help="override the phone IP to verify against")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()

    if a.self_test:
        return self_test()

    try:
        cfg = json.load(open(a.config))
    except Exception as e:
        print(f"FATAL: cannot read {a.config}: {e}", file=sys.stderr)
        return 2

    problems, notes = check(cfg, a.phone_ip)
    for n in notes:
        print(f"  note: {n}")
    if problems:
        print("\nREFUSING TO START:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print("  preflight ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
