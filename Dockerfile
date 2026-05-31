# Stage 1: Build
FROM alpine:edge AS builder

# Install Zig and build dependencies
RUN apk add --no-cache zig build-base sqlite-dev ca-certificates

WORKDIR /app

# Copy project files
COPY . .

# Build the Spline daemon in ReleaseFast mode
RUN zig build -Doptimize=ReleaseFast

# Stage 2: Runtime
FROM alpine:3.19

# Install runtime dependencies (SQLite and CA certificates for HTTPS)
RUN apk add --no-cache sqlite-libs ca-certificates

WORKDIR /app

# Create a data directory for the SQLite database volume
RUN mkdir -p /app/data

# Copy the compiled binary from the builder stage
COPY --from=builder /app/zig-out/bin/spline .

# Run the daemon
CMD ["./spline"]
