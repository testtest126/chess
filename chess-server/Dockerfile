# ================================
# Build image
# ================================
FROM swift:5.10-jammy AS build

WORKDIR /workspace

# The server depends on the sibling ChessKit package, so the build context
# must be the repository root:  docker build -f chess-server/Dockerfile .
COPY ChessKit ./ChessKit
COPY chess-server ./chess-server

WORKDIR /workspace/chess-server
RUN swift build -c release --product App

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

# Required at runtime: JWT_SECRET, DATABASE_URL (postgres://...)
ENV LOG_LEVEL=info
EXPOSE 8080

ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
