# Copyright (c) 2020 Fluent Networks Inc & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

############################################################################
#
# WARNING: Tailscale is not yet officially supported in Docker,
# Kubernetes, etc.
#
# It might work, but we don't regularly test it, and it's not as polished as
# our currently supported platforms. This is provided for people who know
# how Tailscale works and what they're doing.
#
# Our tracking bug for officially support container use cases is:
#    https://github.com/tailscale/tailscale/issues/504
#
# Also, see the various bugs tagged "containers":
#    https://github.com/tailscale/tailscale/labels/containers
#
############################################################################

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build-env

WORKDIR /go/src/tailscale

# This host's toolchain crashes intermittently (cmd/compile SSA race) under
# default parallelism. Serialize compilation - slower, reliable.
ENV GOFLAGS=-p=1

COPY tailscale/go.mod tailscale/go.sum ./
RUN go mod download

RUN apk add --no-cache upx

# Pre-build some stuff before the following COPY line invalidates the Docker cache.
RUN go install \
    github.com/aws/aws-sdk-go-v2/aws \
    github.com/aws/aws-sdk-go-v2/config \
    gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
    gvisor.dev/gvisor/pkg/tcpip/stack \
    golang.org/x/crypto/ssh \
    golang.org/x/crypto/acme \
    github.com/coder/websocket \
    github.com/mdlayher/netlink

COPY tailscale/. .

# see build.sh
ARG VERSION_LONG=""
ENV VERSION_LONG=$VERSION_LONG
ARG VERSION_SHORT=""
ENV VERSION_SHORT=$VERSION_SHORT
ARG VERSION_GIT_HASH=""
ENV VERSION_GIT_HASH=$VERSION_GIT_HASH
ARG TARGETARCH
ARG GOARM="5"

ARG TS_OMIT_TAGS="ts_omit_acme,ts_omit_appconnectors,ts_omit_aws,ts_omit_bird,ts_omit_cachenetmap,ts_omit_captiveportal,ts_omit_capture,ts_omit_cliconndiag,ts_omit_cloud,ts_omit_colorable,ts_omit_completion,ts_omit_completion_scripts,ts_omit_conn25,ts_omit_dbus,ts_omit_debug,ts_omit_debugeventbus,ts_omit_debugportmapper,ts_omit_desktop_sessions,ts_omit_doctor,ts_omit_drive,ts_omit_flashappliance,ts_omit_gro,ts_omit_kube,ts_omit_linkspeed,ts_omit_linuxdnsfight,ts_omit_netlog,ts_omit_networkmanager,ts_omit_outboundproxy,ts_omit_portlist,ts_omit_posture,ts_omit_qrcodes,ts_omit_remoteconfig,ts_omit_resolved,ts_omit_runtimemetrics,ts_omit_sdnotify,ts_omit_serve,ts_omit_serviceclientprefs,ts_omit_ssh,ts_omit_synology,ts_omit_syslog,ts_omit_systray,ts_omit_taildrop,ts_omit_tap,ts_omit_tpm,ts_omit_tundevstats,ts_omit_usermetrics,ts_omit_webbrowser,ts_omit_webclient"

RUN GOARCH=$TARGETARCH GOARM=$GOARM go build -o /go/bin/ -tags "$TS_OMIT_TAGS" -ldflags="-w -s\
      -X tailscale.com/version.Long=$VERSION_LONG \
      -X tailscale.com/version.Short=$VERSION_SHORT \
      -X tailscale.com/version.GitCommit=$VERSION_GIT_HASH" \
      -v ./cmd/tailscale ./cmd/tailscaled

RUN upx /go/bin/tailscale && upx /go/bin/tailscaled

FROM alpine:3.22 AS final

RUN apk add --no-cache ca-certificates iptables iptables-legacy iproute2 bash openssh curl jq

RUN ln -s /usr/sbin/iptables-legacy /usr/local/bin/iptables
RUN ln -s /usr/sbin/ip6tables-legacy /usr/local/bin/ip6tables

RUN ssh-keygen -f /etc/ssh/ssh_host_rsa_key -N '' -t rsa
RUN ssh-keygen -f /etc/ssh/ssh_host_ed25519_key -N '' -t ed25519

COPY --from=build-env /go/bin/* /usr/local/bin/
COPY sshd_config /etc/ssh/
COPY tailscale.sh /usr/local/bin

EXPOSE 22
CMD ["/usr/local/bin/tailscale.sh"]

# musl.cc's own HTTP server is too flaky for CI-scale downloads (100MB tarball
# routinely stalls/times out on GitHub Actions runners). Pull the identical
# toolchain from musl.cc's own published Docker image instead - registry
# pulls are cached/mirrored infra, not a single small server.
FROM --platform=$BUILDPLATFORM muslcc/x86_64:arm-linux-musleabi AS musl-cross

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS musl-rootfs

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates build-essential bc bison flex qemu-user-static && \
    rm -rf /var/lib/apt/lists/*

COPY --from=musl-cross / /opt/arm-linux-musleabi-cross/

# This image's /bin holds the cross toolchain under unprefixed names (gcc,
# ar, ld, ...) alongside its own busybox - it's meant to be run as a whole
# environment, not layered onto another distro's PATH. Adding it to PATH
# directly shadows the host's own gcc/etc, breaking any host-tool build step
# (e.g. busybox's HOSTCC). Symlink just the compiler/binutils names into
# their arm-linux-musleabi- prefixed form instead, so CROSS_COMPILE=
# arm-linux-musleabi- finds them while plain `gcc` still resolves to Debian's.
RUN mkdir -p /opt/arm-linux-musleabi-cross/prefixed-bin && \
    for t in gcc g++ c++ cpp ar as ld ld.bfd ld.gold nm ranlib strip \
             objcopy objdump readelf addr2line size elfedit dwp \
             gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool gprof strings; do \
      ln -s "../bin/$t" "/opt/arm-linux-musleabi-cross/prefixed-bin/arm-linux-musleabi-$t"; \
    done
ENV PATH="/opt/arm-linux-musleabi-cross/prefixed-bin:${PATH}"
ENV CROSS="arm-linux-musleabi-"

# --- BusyBox: shell (ash), coreutils, ip, chpasswd, sysctl - one static binary.
# Downloaded to a file first, not piped straight into tar: a piped download
# that gets truncated mid-stream just looks like a corrupt archive to tar,
# with no retry. --retry lets curl actually recover from that.
ARG BUSYBOX_VERSION="1.36.1"
RUN mkdir -p /usr/src && \
    curl --fail --retry 5 --retry-all-errors -sL "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" -o /tmp/busybox.tar.bz2 && \
    tar -xj -C /usr/src -f /tmp/busybox.tar.bz2 && rm /tmp/busybox.tar.bz2
WORKDIR /usr/src/busybox-1.36.1
RUN make ARCH=arm CROSS_COMPILE=${CROSS} defconfig && \
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config && \
    yes '' | make ARCH=arm CROSS_COMPILE=${CROSS} oldconfig && \
    make ARCH=arm CROSS_COMPILE=${CROSS} -j"$(nproc)" busybox

# --- Dropbear: sshd. Far smaller and simpler than OpenSSH for a musl/embedded
# target - no PAM, no autotools dependency chain, self-contained crypto.
ARG DROPBEAR_VERSION="2025.88"
RUN curl --fail --retry 5 --retry-all-errors -sL "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2" -o /tmp/dropbear.tar.bz2 && \
    tar -xj -C /usr/src -f /tmp/dropbear.tar.bz2 && rm /tmp/dropbear.tar.bz2
WORKDIR /usr/src/dropbear-2025.88
RUN CC=${CROSS}gcc ./configure --host=arm-linux-musleabi --enable-static \
      --disable-zlib --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
      --disable-lastlog --disable-loginfunc --disable-pututline --disable-pututxline \
      LDFLAGS=-static && \
    make PROGRAMS="dropbear dropbearkey" STATIC=1 -j"$(nproc)"

# --- iptables: legacy backend only (no nftables/libmnl) - needed for
# tailscale's netfilter mode.
ARG IPTABLES_VERSION="1.8.9"
RUN curl --fail --retry 5 --retry-all-errors -sL "https://www.netfilter.org/pub/iptables/iptables-${IPTABLES_VERSION}.tar.xz" -o /tmp/iptables.tar.xz && \
    tar -xJ -C /usr/src -f /tmp/iptables.tar.xz && rm /tmp/iptables.tar.xz
WORKDIR /usr/src/iptables-1.8.9
RUN CC=${CROSS}gcc ./configure --host=arm-linux-musleabi \
      --disable-nftables --disable-connlabel --disable-shared --enable-static \
      LDFLAGS=-static && \
    make -j"$(nproc)"

# --- Assemble the rootfs.
WORKDIR /
RUN set -e; \
    mkdir -p /rootfs/bin /rootfs/lib /rootfs/usr/sbin /rootfs/usr/local/bin \
             /rootfs/etc/dropbear /rootfs/etc/ssl/certs /rootfs/root/.ssh /rootfs/var/run; \
    cp /usr/src/busybox-1.36.1/busybox /rootfs/bin/busybox; \
    chroot /rootfs /bin/busybox --install -s /bin; \
    cp /usr/src/dropbear-2025.88/dropbear /rootfs/usr/sbin/dropbear; \
    cp /opt/arm-linux-musleabi-cross/arm-linux-musleabi/lib/libc.so /rootfs/lib/ld-musl-arm.so.1; \
    ln -s ld-musl-arm.so.1 /rootfs/lib/libc.so; \
    cp /usr/src/iptables-1.8.9/iptables/xtables-legacy-multi /rootfs/usr/sbin/xtables-legacy-multi; \
    for t in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do \
      ln -s xtables-legacy-multi /rootfs/usr/sbin/$t; \
      ln -s /usr/sbin/$t /rootfs/usr/local/bin/$t; \
    done

# Host keys, generated at build time like the other stages.
RUN cp /usr/src/dropbear-2025.88/dropbearkey /rootfs/usr/sbin/dropbearkey && \
    chroot /rootfs /usr/sbin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key && \
    chroot /rootfs /usr/sbin/dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key && \
    chroot /rootfs /usr/sbin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key && \
    rm /rootfs/usr/sbin/dropbearkey

# Minimal user/host db - musl reads /etc/passwd,/etc/shadow,/etc/group
# directly (no nsswitch). Root's shadow entry starts locked; tailscale.sh
# sets the real password via chpasswd from $PASSWORD at container start.
RUN printf 'root:x:0:0:root:/root:/bin/ash\n' > /rootfs/etc/passwd && \
    printf 'root:!:19000:0:99999:7:::\n' > /rootfs/etc/shadow && \
    printf 'root:x:0:\n' > /rootfs/etc/group && \
    printf '127.0.0.1 localhost\n' > /rootfs/etc/hosts && \
    printf 'export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' > /rootfs/etc/profile && \
    chmod 600 /rootfs/etc/shadow

RUN curl -sL https://curl.se/ca/cacert.pem -o /rootfs/etc/ssl/certs/ca-certificates.crt

COPY tailscale.sh /rootfs/usr/local/bin/

FROM scratch AS final-v7
COPY --from=musl-rootfs /rootfs/ /
COPY --from=build-env /go/bin/* /usr/local/bin/

EXPOSE 22
CMD ["/usr/local/bin/tailscale.sh"]

# ---------------------------------------------------------------------------
ARG TARGETVARIANT
FROM final${TARGETVARIANT:+-v7}

