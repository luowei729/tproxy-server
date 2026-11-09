# syntax=docker/dockerfile:1.6
#
# Merged WEB relay + official MTProxy image.
#
# MTProxy needs glibc's drand48_r family, which musl does not provide, so the
# build and runtime stages use Debian. A static musl build would require
# patching the pinned upstream source, which this project deliberately does not
# do.

ARG DEBIAN_IMAGE=debian:bookworm-slim
ARG GO_IMAGE=golang:1.23-bookworm

FROM ${DEBIAN_IMAGE} AS mtproxy
ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_SHA256=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl libssl-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
      -o mtproxy.tar.gz \
      "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
 && echo "${MTPROXY_SHA256}  mtproxy.tar.gz" | sha256sum -c - \
 && tar -xzf mtproxy.tar.gz --strip-components=1 \
 && rm mtproxy.tar.gz \
 && make -j"$(nproc)" \
 && install -m 0755 objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy

FROM ${GO_IMAGE} AS relay
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN go build -trimpath -ldflags='-s -w' -o /out/tproxy-server ./cmd/tproxy-server

FROM ${DEBIAN_IMAGE} AS runtime
ARG TPROXY_UID=65532
ARG TPROXY_GID=65532
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl libssl3 util-linux zlib1g \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid "${TPROXY_GID}" tproxy \
 && useradd --system --uid "${TPROXY_UID}" --gid tproxy \
      --home-dir /nonexistent --shell /usr/sbin/nologin tproxy \
 && install -d -o root -g root -m 0755 /data
COPY --from=mtproxy /usr/local/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY --from=relay /out/tproxy-server /usr/local/bin/tproxy-server
# A placeholder public site so the container starts without a host mount. It is
# the response an unauthenticated prober sees, so replace it with the operator's
# real site (TPROXY_PUBLIC_DIR or TPROXY_PUBLIC_UPSTREAM) before going live.
COPY deploy/docker/site /srv/site
COPY deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY deploy/docker/tproxy-run.sh /usr/local/bin/tproxy-run
RUN chmod 0755 \
      /usr/local/bin/entrypoint.sh \
      /usr/local/bin/tproxy-run \
      /usr/local/bin/mtproto-proxy \
      /usr/local/bin/tproxy-server \
 && chmod -R a+rX /srv/site
EXPOSE 65501
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["curl", "-fsS", "http://127.0.0.1:65502/healthz"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
