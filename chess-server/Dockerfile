# ================================
# Build image
# ================================
# vapor/jwt 5.x requires Swift tools 6.0; the 5.10 base can no longer
# resolve dependencies.
FROM swift:6.0-jammy AS build

WORKDIR /workspace

# The server depends on the sibling ChessKit package, so the build context
# must be the repository root:  docker build -f chess-server/Dockerfile .
COPY ChessKit ./ChessKit
COPY chess-server ./chess-server

WORKDIR /workspace/chess-server
# Static stdlib: the run stage has no Swift runtime libs, so a dynamically
# linked binary would fail at exec.
RUN swift build -c release --product App --static-swift-stdlib

# ================================
# Run image
# ================================
FROM ubuntu:jammy

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libcurl4 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --system vapor
WORKDIR /app
COPY --from=build /workspace/chess-server/.build/release/App ./App
USER vapor

# Required at runtime: JWT_SECRET (secret), and a database — DATABASE_URL
# (postgres://…) or SQLITE_PATH (file on a mounted volume).
ENV LOG_LEVEL=info
EXPOSE 8080

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
