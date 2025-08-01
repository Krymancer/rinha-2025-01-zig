FROM alpine:latest AS builder
RUN apk add --no-cache \
  curl \
  xz \
  git \
  build-base \
  linux-headers \
  zig
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ ./src/
RUN zig build -Doptimize=ReleaseFast 
FROM alpine
RUN apk add --no-cache libc6-compat sqlite
RUN adduser -D -s /bin/sh appuser
COPY --from=builder /app/zig-out/bin/backend /usr/local/bin/backend
USER appuser
EXPOSE 8080
CMD ["backend"]
