# Docker deployment: merged WEB relay and MTProxy

One container runs both halves of the proxy behind an existing HTTPS website:

```text
Telegram app (hostname = xxx.com, always port 443)
        |
        v
existing nginx :443  (real website on /)
        |
        |  location ^~ /proxy/
        v
127.0.0.1:65501  (published by Docker on host loopback only)
        |
        v
tproxy container
  tproxy-server 0.0.0.0:65501 -> 127.0.0.1:2398 official MTProxy
```

The relay keeps the whole WEB surface — bridge page, bootstrap, session, and the
four carrier modes — under `/proxy/`. Telegram still speaks its normal MTProxy
protocol; the relay only separates the WebView streams and hands each one to the
stock MTProxy. Nothing about the client changes: the hostname stays `xxx.com`.

## Why these choices

- **Debian, not Alpine.** The pinned MTProxy source uses `drand48_r`,
  `srand48_r`, `lrand48_r`, and `mrand48_r`, which musl does not provide. A musl
  build needs source patches, and this project does not modify the pinned
  upstream build. The image is `debian:bookworm-slim` plus four small packages.
- **Bridge networking, not host networking.** With host networking MTProxy binds
  `0.0.0.0:2398` on the host and stays exposed unless an external firewall drops
  it. In a bridge network it is reachable only from inside the container. The
  relay port is the only published one, and only on host loopback.
- **`container_network: true`.** The relay normally refuses non-loopback
  listeners and peers. A published Docker port cannot reach a loopback-only
  listener, so the container binds `0.0.0.0:65501` and sees the Docker gateway as
  its peer. The flag enables exactly that and is set by the entrypoint; it is
  never on in the systemd deployment. The published loopback port remains the
  trust boundary.
- **No certificate and no domain TLS on the backend.** The reverse proxy in front
  already terminates TLS on 443, so the container speaks plain HTTP. It never
  loads a certificate, never reads `TPROXY_TLS_*`, and never needs ports 80 or
  443 or an ACME account. `TPROXY_HOSTNAME` is not a certificate name here: it is
  only the value that the bridge capability is derived from and the value the
  relay compares against the incoming `Host` header.

Because of that Host comparison, the front proxy must forward the public name:

```nginx
proxy_set_header Host $host;   # xxx.com, not 127.0.0.1:65501
```

nginx's default for `proxy_pass` is `proxy_set_header Host $proxy_host`, which
sends `127.0.0.1:65501`. Every carrier request would then be answered with the
public 404 and the bridge page would load but never connect. Set it explicitly.

## One command

No checkout, no compose file, no host directories to create. The image ships a
placeholder site at `/srv/site`, so the container starts by itself:

```bash
docker run -d --name tproxy --restart unless-stopped \
  --read-only --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  -p 127.0.0.1:65501:65501 \
  -v tproxy-data:/data \
  -e TPROXY_HOSTNAME=xxx.com \
  -e TPROXY_SECRET=000102030405060708090a0b0c0d0e0f \
  ghcr.io/luowei729/tproxy-server:latest
```

That placeholder is the response an unauthenticated prober receives for any path
under the prefix. It is generic and shared by every deployment of this image, so
replace it before distributing links — a repeated body is itself a fingerprint.

There is no domain, certificate, ACME, `server_name`, or 80/443 setup here: TLS
ends at the reverse proxy in front and this container speaks plain HTTP on
loopback. `TPROXY_HOSTNAME` is a protocol input, not a certificate name — it is
the `hostname` in the capability derivation and the value the relay compares
against the forwarded `Host` — so it must equal the hostname clients type. It is
the only hostname-shaped setting in the command.

### Replace the placeholder with the real site

Either mount a copy over the built-in path:

```bash
sudo mkdir -p /srv/www/site
sudo cp -a /var/www/xxx.com/. /srv/www/site/     # include 404.html if you have one
docker run -d --name tproxy --restart unless-stopped \
  ... -v /srv/www/site:/srv/site:ro ...
```

or serve the site once more on a loopback port and give the relay that address.
This keeps a single copy of the site and matches its behaviour exactly:

```nginx
server {
    listen 127.0.0.1:3000;
    server_name _;
    root /var/www/xxx.com;
    index index.html;
    error_page 404 /404.html;
}
```

```bash
# 172.17.0.1 is the Docker bridge gateway, i.e. the host, from inside a container.
# Confirm with: ip -4 addr show docker0
docker run -d --name tproxy --restart unless-stopped \
  ... -e TPROXY_PUBLIC_UPSTREAM=http://172.17.0.1:3000 ...
```

`TPROXY_PUBLIC_UPSTREAM` accepts only `http://`, a numeric address, and a port.
It is not a public URL: the relay reaches it over the container network.

> If you mount a host directory that does not exist, Docker creates it empty
> instead of failing, and the container restart-loops with
> `TPROXY_PUBLIC_DIR must contain a readable index.html`. Create it first.

Then proxy one prefix to it from the existing nginx:

```nginx
location ^~ /proxy/ {
    proxy_pass http://127.0.0.1:65501;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 90s;
    proxy_send_timeout 90s;
    proxy_buffering off;
    proxy_request_buffering off;
    client_max_body_size 4m;
    access_log off;
}
```

`TPROXY_BASE_PATH` defaults to `proxy`. Override it for a different prefix, or
set it empty for the host root:

```bash
docker run -d --name tproxy --restart unless-stopped \
  --read-only --tmpfs /run --tmpfs /tmp \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  -p 127.0.0.1:65501:65501 -v tproxy-data:/data \
  -e TPROXY_HOSTNAME=xxx.com \
  -e TPROXY_BASE_PATH=my-secret-path \
  -e TPROXY_SECRET=000102030405060708090a0b0c0d0e0f \
  ghcr.io/luowei729/tproxy-server:latest
```

Manage it with ordinary Docker commands:

```bash
docker logs -f tproxy
docker restart tproxy
docker rm -f tproxy              # the tproxy-data volume survives
docker pull ghcr.io/luowei729/tproxy-server:latest && docker restart tproxy
```

## Quick start with compose

```bash
cd deploy/docker
cp .env.example .env
# Edit .env: TPROXY_HOSTNAME and TPROXY_SECRET. The site is optional: the image
# contains a placeholder, and TPROXY_PUBLIC_DIR/TPROXY_PUBLIC_UPSTREAM override it.
chmod 0755 client-link.sh
docker compose up -d --build
```

The named volume `tproxy-data` keeps the token signing key, `proxy-secret`, and
`proxy-multi.conf` across restarts. Deleting it invalidates live sessions and
re-downloads the MTProxy files.

`TPROXY_BASE_PATH` defaults to `proxy` and accepts the same syntax as the
systemd installer: `/`-separated segments matching `[A-Za-z0-9][A-Za-z0-9_-]*`,
at most 128 characters. An empty value serves the relay at the host root.

## Build in CI, pull on the server

`.github/workflows/docker.yml` runs `go vet` and `go test`, then builds
`linux/amd64` and pushes to GHCR on every push to the default branch, on `v*`
tags, and on manual dispatch. Tags are `latest` (default branch), the branch
name, semver, and `sha-<short>`.

The workflow needs no extra secret: it authenticates with `GITHUB_TOKEN` and
`packages: write`. Make the package public once, or authenticate the server:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

On the server, pull instead of building:

```bash
cd deploy/docker
cp .env.example .env
# TPROXY_IMAGE=ghcr.io/<owner>/<repo>:latest
docker compose pull
docker compose up -d
```

`docker compose up -d` without `--build` starts the pulled image. To pin a
release, use a `sha-<short>` or semver tag instead of `latest` and update it
deliberately. Rolling back is changing that tag and running
`docker compose pull && docker compose up -d`; the `tproxy-data` volume keeps
the token key so sessions issued before the rollback stay recognizable.

Only `linux/amd64` is published. The pinned MTProxy source builds with
`-march=core2` and needs glibc, so an arm64 image would need a different MTProxy
build, not just another platform entry.

## nginx on the same host

The hop from nginx to the container is plain HTTP: `http://127.0.0.1:65501`.
The relay never terminates TLS and has no certificate. nginx keeps the 443
certificate and the website, so do not add `proxy_ssl_*`, `ssl` on the upstream,
or an `https://` upstream address.

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      "";
}

upstream tproxy_relay {
    server 127.0.0.1:65501;         # plain HTTP, no TLS
    keepalive 32;
}

server {
    listen 443 ssl;
    http2 on;
    server_name xxx.com;

    # ... your existing TLS and website configuration ...

    client_max_body_size 4m;        # carrier batches reach 2 MiB

    location ^~ /proxy/ {
        proxy_pass http://tproxy_relay;   # http://, not https://
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 90s;     # relay long_poll is 25s
        proxy_send_timeout 90s;
        proxy_buffering off;
        proxy_request_buffering off;
        access_log off;
    }

    location / {
        # your existing website
    }
}
```

Inside the container the relay binds `0.0.0.0:65501`, because a Docker published
port cannot reach a loopback-only listener. That address is container-internal:
the published port is bound to `127.0.0.1` on the host, so from nginx and from the
host the only address is `http://127.0.0.1:65501`, and nothing on the network can
reach it directly. `container_network: true` in the generated config exists only
to permit that non-loopback container listener and peer.

Keep the decoy consistent: the relay answers unauthenticated requests under the
prefix from the built-in placeholder unless you mount or proxy the real site, so
a probe of `/proxy/whatever` should receive the website's own 404 rather than a
distinguishable relay error. If the site runs as an application on the host, set
`TPROXY_PUBLIC_UPSTREAM` to a container-reachable address (for example
`http://172.17.0.1:3000`) instead of mounting files.

The relay requires exactly one `X-Forwarded-For` value; `$proxy_add_x_forwarded_for`
can produce a list and is rejected.

## Client link

```bash
./client-link.sh
```

It prints the proxy server (`xxx.com/proxy`), the marked secret, and the
`https://t.me/webproxy?...` link. The raw hex secret is only the MTProxy backend
credential; never paste it into the client for a prefixed deployment.

## MTProxy and NAT

MTProxy derives its middle-end AES keys from its own source address. Docker
translates that address, so the container always needs `--nat-info`. The
entrypoint detects the container address and probes the public address, then
passes `--nat-info <local>:<public>`. Behind provider 1:1 NAT, set
`MTPROXY_PUBLIC_IP` explicitly. Without a correct pair MTProxy accepts clients,
answers none, and every stream stalls silently — check:

```bash
docker logs tproxy 2>&1 | grep -c 'Disconnected from RPC Middle-End'
```

A steady count means the pair is wrong.

## Verification

```bash
docker compose ps
docker logs tproxy
curl -fsS http://127.0.0.1:65502/healthz

# The public site is untouched.
curl -fsSI https://xxx.com/
# A probe under the prefix gets the site's own 404, not a relay error.
curl -fsSI https://xxx.com/proxy/whatever

# The bridge requires a valid capability derived from host + path + secret.
# Use client-link.sh to produce a client, or load the bridge URL from a client.
```

Also confirm the container ports are not reachable from another host:

```bash
nc -vz -w 3 xxx.com 65501   # must fail: published on host loopback only
nc -vz -w 3 xxx.com 2398    # must fail: MTProxy is container-internal
```

## Security notes

- Publish the relay port on `127.0.0.1` only. Publishing it on `0.0.0.0` lets
  anyone reach the carrier endpoints and spoof `X-Forwarded-For`, which defeats
  the per-IP limits.
- Keep `no-new-privileges`, `cap_drop: ALL`, and the three added capabilities.
  The entrypoint needs `CHOWN`, `SETUID`, and `SETGID` only to provision `/data`
  and drop to `tproxy`.
- `docker logs` never contains the raw secret; the entrypoint logs only the
  hostname, base path, and listener.
- The relay is `read_only`; `/data` and `/run` are the only writable paths.
