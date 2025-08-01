FROM alpine:latest AS builder
RUN apk add --no-cache \
  curl \
  xz \
  git \
  build-base \
  linux-headers \
  zig
WORKDIR /app
COPY build.zig .
COPY build.zig.zon .
COPY src/ src/
RUN zig build -Doptimize=ReleaseFast
FROM alpine:latest
RUN apk add --no-cache libc6-compat
RUN addgroup -g 1001 -S ziguser && \
  adduser -S ziguser -u 1001
COPY --from=builder /app/zig-out/bin/rinha-backend /usr/local/bin/rinha-backend
RUN chown ziguser:ziguser /usr/local/bin/rinha-backend
USER ziguser
EXPOSE 9999
ENTRYPOINT ["/usr/local/bin/rinha-backend"]