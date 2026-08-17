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

RUN GOARCH=$TARGETARCH GOARM=$GOARM go build -o /go/bin/ -ldflags="-w -s\
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

# ---------------------------------------------------------------------------
# arm/v7 (soft-float): bootstrap Devuan excalibur armel rootfs. Debian/Alpine
# dropped soft-float ARM32 (armel) entirely; Devuan still ships it current.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS devuan-rootfs

ARG DEVUAN_KEYRING_VERSION="2025.08.09"

# Some CI runners have a broken/blackholed IPv6 route, making every apt/wget
# connection try IPv6 first, stall, then fall back to IPv4 - can turn a 5min
# debootstrap into a 20min timeout. Force IPv4 everywhere in this stage.
RUN echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

RUN apt-get update && apt-get install -y --no-install-recommends \
      debootstrap qemu-user-static ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

# wget's own postinst must run first - writing this earlier collides with
# the conffile it installs.
RUN echo "inet4-only = on" > /etc/wgetrc

RUN curl -sL "http://deb.devuan.org/merged/pool/DEVUAN/main/d/devuan-keyring/devuan-keyring_${DEVUAN_KEYRING_VERSION}_all.deb" -o /tmp/dk.deb && \
    dpkg-deb -x /tmp/dk.deb /tmp/dkx

RUN debootstrap --arch=armel \
      --keyring=/tmp/dkx/usr/share/keyrings/devuan-archive-keyring.gpg \
      --variant=minbase excalibur /rootfs \
      http://deb.devuan.org/merged /usr/share/debootstrap/scripts/trixie

RUN cp /etc/resolv.conf /rootfs/etc/resolv.conf && \
    mkdir -p /rootfs/etc/apt/apt.conf.d && \
    echo 'Acquire::ForceIPv4 "true";' > /rootfs/etc/apt/apt.conf.d/99force-ipv4 && \
    chroot /rootfs apt-get update && \
    chroot /rootfs apt-get install -y --no-install-recommends \
      ca-certificates iptables iproute2 bash openssh-server procps && \
    chroot /rootfs apt-get clean && \
    rm -rf /rootfs/var/lib/apt/lists/* /rootfs/var/cache/apt/* /rootfs/etc/resolv.conf

RUN rm -rf \
      /rootfs/var/lib/dpkg \
      /rootfs/var/lib/apt \
      /rootfs/usr/share/doc \
      /rootfs/usr/share/man \
      /rootfs/usr/share/info \
      /rootfs/usr/share/locale \
      /rootfs/usr/share/i18n \
      /rootfs/usr/lib/*/perl* \
      /rootfs/usr/lib/*/perl-base \
      /rootfs/usr/share/perl5 \
      /rootfs/usr/share/perl \
      /rootfs/usr/bin/perl* \
      /rootfs/usr/bin/apt* \
      /rootfs/usr/lib/apt \
      /rootfs/etc/apt \
      /rootfs/usr/lib/*/gconv \
      /rootfs/usr/lib/*/libapt-pkg.so* \
      /rootfs/usr/lib/*/libapt-private.so* \
      /rootfs/usr/lib/*/libdb-5.3.so*

RUN ln -sf /usr/sbin/iptables-legacy /rootfs/usr/local/bin/iptables && \
    ln -sf /usr/sbin/ip6tables-legacy /rootfs/usr/local/bin/ip6tables

# openssh-server postinst already generated host keys.
COPY sshd_config.devuan /rootfs/etc/ssh/sshd_config
COPY tailscale.sh /rootfs/usr/local/bin/

FROM scratch AS final-v7
COPY --from=devuan-rootfs /rootfs/ /
COPY --from=build-env /go/bin/* /usr/local/bin/

EXPOSE 22
CMD ["/usr/local/bin/tailscale.sh"]

# ---------------------------------------------------------------------------
ARG TARGETVARIANT
FROM final${TARGETVARIANT:+-v7}

