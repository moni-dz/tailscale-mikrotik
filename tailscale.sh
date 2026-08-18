#!/bin/sh
# Copyright (c) 2024 Fluent Networks Pty Ltd & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.
#
# POSIX sh: runs under both bash (Alpine stage) and busybox ash (musl stage).

set -m

export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# /run may not exist in the container rootfs; iptables needs it for xtables.lock
mkdir -p /run

# Enable IP forwarding
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf

# Prepare run dirs (OpenSSH privsep dir; no-op under dropbear)
if [ -x /usr/sbin/sshd ] && [ ! -d "/var/run/sshd" ]; then
  mkdir -p /var/run/sshd
fi

# Set root password
echo "root:${PASSWORD}" | chpasswd

# Install routes
OLDIFS="$IFS"
IFS=','
for s in $ADVERTISE_ROUTES; do
  ip route add "$s" via "${CONTAINER_GATEWAY}"
done
IFS="$OLDIFS"

# Perform an update if set
if [ -n "${UPDATE_TAILSCALE+x}" ]; then
  /usr/local/bin/tailscale update --yes
fi

# Set login server for tailscale
if [ -z "${LOGIN_SERVER}" ]; then
	LOGIN_SERVER=https://controlplane.tailscale.com
fi

# Execute startup script if it exists
if [ -n "${STARTUP_SCRIPT}" ] && [ -f "${STARTUP_SCRIPT}" ]; then
       sh "${STARTUP_SCRIPT}" || exit $?
fi

# Start tailscaled and bring tailscale up
/usr/local/bin/tailscaled ${TAILSCALED_ARGS} &
until /usr/local/bin/tailscale up \
  --reset --authkey="${AUTH_KEY}" \
	--login-server "${LOGIN_SERVER}" \
	--advertise-routes="${ADVERTISE_ROUTES}" \
  ${TAILSCALE_ARGS}
do
    sleep 0.1
done
echo Tailscale started

# Check that a route exists for 100.64.0.0/10; if not, add
EXISTS=`ip route show 100.64.0.0/10 | wc -l`
if [ "$EXISTS" -eq 0 ]; then
  ip route add 100.64.0.0/10 dev tailscale0
fi

# Check that a route exists for fd7a:115c:a1e0::/48; if not, add
EXISTSV6=`ip -6 route show fd7a:115c:a1e0::/48 | wc -l`
if [ "$EXISTSV6" -eq 0 ]; then
  ip -6 route add fd7a:115c:a1e0::/48 dev tailscale0
fi

# Execute running script if it exists
if [ -n "${RUNNING_SCRIPT}" ] && [ -f "${RUNNING_SCRIPT}" ]; then
       sh "${RUNNING_SCRIPT}" || exit $?
fi

# Start SSH (OpenSSH on the Alpine stage, dropbear on the musl stage)
if [ -x /usr/sbin/dropbear ]; then
  exec /usr/sbin/dropbear -F -E -j -k -p 22
else
  exec /usr/sbin/sshd -D
fi
