FROM alpine AS builder
RUN apk add zig
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ ./src/
# Use ReleaseFast for maximum performance
RUN zig build -Doptimize=ReleaseFast --summary all

FROM alpine
RUN apk add --no-cache libc6-compat
RUN adduser -D -s /bin/sh appuser
COPY --from=builder /app/zig-out/bin/backend /usr/local/bin/backend
USER appuser
EXPOSE 8080
CMD ["backend"]