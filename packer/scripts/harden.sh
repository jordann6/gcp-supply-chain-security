#!/usr/bin/env bash
#
# CIS-informed hardening for Ubuntu 22.04 on GCE.
#
# Deliberately not a full CIS Level 2 run. A benchmark applied wholesale to a
# cloud base image breaks the guest environment agent, the OS Login PAM stack,
# or the metadata server, and the failure shows up as instances that boot and
# cannot be logged into. What is here is the subset that survives contact with
# GCE and that a reviewer can check in a minute.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> Waiting for cloud-init so apt is not fighting the boot"
cloud-init status --wait >/dev/null 2>&1 || true

echo "==> Patching"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq auditd apparmor-utils unattended-upgrades

echo "==> Unattended security upgrades"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "==> SSH daemon"
# Password auth and root login are already off in Canonical's GCE image. They
# are set again here because "already off by default" is a property of today's
# base image, not a property of this image.
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/60-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 60
EOF
chmod 0600 /etc/ssh/sshd_config.d/60-hardening.conf

echo "==> Kernel and network sysctls"
cat >/etc/sysctl.d/60-hardening.conf <<'EOF'
# No routing. This is a workload host, not a router, and IP forwarding on a
# compromised host is how a foothold becomes a pivot.
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# ASLR, and no core dumps from setuid binaries.
kernel.randomize_va_space = 2
fs.suid_dumpable = 0

# Kernel pointers stay out of /proc for unprivileged readers, and dmesg is not
# a public log.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
sysctl --system >/dev/null

echo "==> Filesystem modules nobody needs on a cloud VM"
cat >/etc/modprobe.d/60-hardening.conf <<'EOF'
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
install usb-storage /bin/true
EOF

echo "==> Audit rules"
cat >/etc/audit/rules.d/60-hardening.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /var/log/sudo.log -p wa -k actions
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k privileged
EOF
systemctl enable auditd >/dev/null

echo "==> AppArmor enforcing"
systemctl enable apparmor >/dev/null
aa-enforce /etc/apparmor.d/* >/dev/null 2>&1 || true

echo "==> Permissions on the files that decide who is who"
chmod 0644 /etc/passwd /etc/group
chmod 0640 /etc/shadow /etc/gshadow
chmod 0600 /etc/crontab

echo "==> Removing packages that have no business on a server image"
apt-get purge -y -qq telnet rsh-client talk 2>/dev/null || true
apt-get autoremove -y -qq
apt-get clean

echo "==> Clearing bake artifacts"
# Anything created during the bake that would otherwise be baked in: the SSH
# host keys (identical host keys across a fleet defeat host verification), the
# machine ID, shell history, and Packer's own key.
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -rf /root/.ssh /home/packer/.ssh /var/lib/cloud/instances
rm -f /root/.bash_history /home/*/.bash_history
find /var/log -type f -exec truncate -s 0 {} \;

echo "==> Hardening complete"
