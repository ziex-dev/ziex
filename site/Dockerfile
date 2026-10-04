FROM alpine:3.22.2 AS build

# Install Zig
ARG ZIG_VER=0.17.0
RUN wget https://ziglang.org/builds/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz && \
    tar -xf zig-*.tar.xz && \
    rm zig-*.tar.xz && \
    mv zig-*/ /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

# Build App
WORKDIR /build

# Node Deps
RUN apk add --no-cache nodejs npm curl
COPY site/package.json site/package-lock.json ./site/
RUN cd site && npm ci

# Ziex CLI
COPY build.zig build.zig.zon README.md ./
COPY src ./src
COPY vendor ./vendor
COPY pkg ./pkg
COPY templates ./templates

COPY site/build.zig site/build.zig.zon ./site/
RUN cd site && zig build --fetch

# App
RUN cd site && zig build pg

COPY site/app ./site/app
COPY site/component ./site/component
COPY pkg/ui ./pkg/ui
RUN cd site && zig build -Doptimize=ReleaseSmall

# Run App
FROM alpine:3.22.2

# Fonts
RUN apk add --no-cache font-inter font-croscore

WORKDIR /app
COPY --from=build /build/site/zig-out/bin/ziex_dev /app/ziex_dev
COPY --from=build /build/site/zig-out/static /app/static

ENTRYPOINT ["/app/ziex_dev"]