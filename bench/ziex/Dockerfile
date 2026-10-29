FROM alpine:3.22.2 AS build

# Setup Zig
ARG ZIG_VER=0.18.0-dev.738+ae9a8acc7
RUN wget https://ziglang.org/builds/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz && \
    tar -xf zig-*.tar.xz && \
    rm zig-*.tar.xz && \
    mv zig-*/ /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /build

# Ziex
COPY build.zig build.zig.zon README.md ./
COPY src/ src/
COPY vendor/ vendor/
COPY pkg/ pkg/
COPY templates/Template.zig templates/Template.zig
COPY templates/_base templates/_base
COPY templates/_docker templates/_docker

# App
COPY ./bench/ziex/build.zig bench/ziex/build.zig.zon ./bench/ziex/
COPY ./bench/ziex/app ./bench/ziex/app
RUN cd bench/ziex && zig build zx -- build --build-args="--release=fast -Dcpu=baseline -Dtarget=$(uname -m)-linux-musl"

# Run app
FROM alpine:3.22.2
WORKDIR /app

COPY --from=build /build/bench/ziex/zig-out/bin /app
COPY --from=build /build/bench/ziex/zig-out/static /app/static

ENTRYPOINT ["/app/ziex_app"]