# Stage 1: Build
FROM alpine:3.23 AS builder

# Install Zig and build dependencies
RUN apk add --no-cache zig build-base sqlite-dev ca-certificates

WORKDIR /app

# Copy project files
COPY . .

# Build the Spline daemon in ReleaseFast mode
RUN zig build -Doptimize=ReleaseFast

# Stage 2: Runtime
FROM alpine:3.23

# Install runtime dependencies (SQLite and CA certificates for HTTPS)
RUN apk add --no-cache sqlite-libs ca-certificates \
    && addgroup -S spline \
    && adduser -S -G spline spline

WORKDIR /app

# Create a data directory for the SQLite database volume
RUN mkdir -p /app/data && chown -R spline:spline /app/data

# Copy the compiled binaries from the builder stage
COPY --from=builder /app/zig-out/bin/spline /usr/local/bin/
COPY --from=builder /app/zig-out/bin/lyfta-spline /usr/local/bin/

# Copy the environment file from the build context (builder)
COPY --from=builder /app/.env /app/.env

# Ensure non-root ownership of the app directory
RUN chown -R spline:spline /app

# Run the daemon as the non-root user
USER spline
CMD ["spline"]
