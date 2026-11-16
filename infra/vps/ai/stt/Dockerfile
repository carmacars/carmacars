# r48 part AI: whisper.cpp's HTTP server (speech to text for call and interview recordings), built on the server from a
# pinned release tag (infra/vps/ai/models.env WHISPER_VERSION) for its own CPU. ffmpeg converts any recording (--convert).
FROM debian:bookworm-slim AS build
ARG WHISPER_VERSION=v1.7.6
RUN apt-get update && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp /src \
 && cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF \
 && cmake --build /src/build -j"$(nproc)" --target whisper-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates && rm -rf /var/lib/apt/lists/* \
 && useradd -r -u 10001 -d /models whisper && install -d -o whisper -g whisper /models
COPY --from=build /src/build/bin/whisper-server /usr/local/bin/whisper-server
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
WORKDIR /models
USER whisper
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/usr/local/bin/entrypoint.sh"]
