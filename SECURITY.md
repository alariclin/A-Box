# Security Policy

## Supported versions

Only the current tip of `main` is supported with security fixes. If you
run an older copy of `install.sh`, update to the latest `main` first and
re-check whether the issue still reproduces.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report it privately through GitHub's private vulnerability reporting:
open the **Security** tab of https://github.com/alariclin/A-Box and
choose **Report a vulnerability**. Describe what is affected
(`install.sh` section, protocol, firewall/DNS path), how to reproduce
it, and what an attacker would gain. Screenshots or logs are welcome;
redact keys, UUIDs, passwords, IPs and domain names first.

What happens next:

1. The maintainer triages the report and may ask for clarification in
   the private advisory thread.
2. A fix is prepared and verified (including the `install.sh`
   self-test gate) before any public disclosure.
3. Once fixed, the advisory is published with credit to the reporter
   (unless the reporter asks to stay anonymous).

## Scope notes

- A-Box is a privileged installer: it runs as root, manages firewall
  rules, DNS and proxy cores. Reports about privilege boundaries,
  unsafe file permissions, injection through untrusted input, or
  signature/checksum bypasses are in scope.
- Issues in upstream projects (Xray-core, sing-box, Hysteria,
  cloudflared, Caddy, Wallos) should be reported to those projects
  directly; report them here only if A-Box's own integration is what
  makes them exploitable.
