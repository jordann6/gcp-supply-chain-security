#!/usr/bin/env bash
#
# Fails the bake if the hardening did not take.
#
# Runs as a separate provisioner rather than as the tail of harden.sh, because a
# script that both applies and verifies its own work tends to verify the
# variable it just set rather than the state of the machine.

set -uo pipefail

failures=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  ok    ${label}"
  else
    echo "  FAIL  ${label}"
    failures=$((failures + 1))
  fi
}

echo "==> Verifying"

# sshd -t refuses to run without a host key, and harden.sh has already deleted
# them by this point so that every instance from this family generates its own.
# The two steps conflict, and the first bake failed here rather than shipping an
# unparsed config, which is the gate working. Generating a throwaway key lets the
# syntax check run without reintroducing a baked-in one.
sshd_parses() {
  local tmp
  tmp="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -f "${tmp}/host_key" >/dev/null 2>&1
  local rc=0
  sshd -t -h "${tmp}/host_key" || rc=$?
  rm -rf "${tmp}"
  return "${rc}"
}

check "sshd config parses"            sshd_parses
check "root login disabled"           grep -qx "PermitRootLogin no" /etc/ssh/sshd_config.d/60-hardening.conf
check "password auth disabled"        grep -qx "PasswordAuthentication no" /etc/ssh/sshd_config.d/60-hardening.conf
check "ip forwarding off"             grep -qx "net.ipv4.ip_forward = 0" /etc/sysctl.d/60-hardening.conf
check "aslr full"                     test "$(sysctl -n kernel.randomize_va_space)" = "2"
check "suid core dumps off"           test "$(sysctl -n fs.suid_dumpable)" = "0"
check "dmesg restricted"              test "$(sysctl -n kernel.dmesg_restrict)" = "1"
check "auditd enabled"                systemctl is-enabled auditd
check "apparmor enabled"              systemctl is-enabled apparmor
check "unattended upgrades armed"     grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
check "shadow not world readable"     test "$(stat -c '%a' /etc/shadow)" = "640"
check "telnet client gone"            bash -c '! command -v telnet'
check "usb-storage blocked"           grep -q "install usb-storage /bin/true" /etc/modprobe.d/60-hardening.conf

# Host keys are removed by harden.sh on purpose, so an identical key does not
# ship to every instance built from this family. cloud-init regenerates them on
# first boot, which is also why /var/lib/cloud/instances is cleared. Assert the
# removal rather than the presence: finding a host key here means the cleanup
# silently failed.
check "no baked-in ssh host keys"     bash -c '! ls /etc/ssh/ssh_host_* >/dev/null 2>&1'

if [ "$failures" -ne 0 ]; then
  echo "==> ${failures} check(s) failed, refusing to publish the image"
  exit 1
fi

echo "==> All checks passed"
