FROM alpine:3.22.2 AS build

# Install Zig
ARG ZIG_VER=0.17.0
RUN wget https://ziglang.org/download/${ZIG_VER}/zig-$(uname -m)-linux-${ZIG_VER}.tar.xz && \
    tar -xf zig-*.tar.xz && \
    rm zig-*.tar.xz && \
    mv zig-*/ /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

# Build App
WORKDIR /build

# Node.js dependencies
# RUN apk add --no-cache nodejs npm
# COPY package.json package-lock.json ./
# RUN npm install

# Ziex CLI
COPY build.zig build.zig.zon ./
RUN zig build --fetch
RUN zig build zx -- version

# App
COPY app/ ./app/
RUN zig build -Doptimize=ReleaseSafe
RUN zig build zx -- bundle

# Run App
FROM alpine:3.22.2
WORKDIR /app
COPY --from=build /build/bundle/ /app/
ENTRYPOINT ["/app/$BIN_NAME"]
