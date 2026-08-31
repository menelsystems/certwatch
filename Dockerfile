# build stage: compile to an erlang shipment (a self-contained release)
FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine AS build
WORKDIR /build
COPY gleam.toml manifest.toml ./
COPY src src
RUN gleam export erlang-shipment

# runtime stage: same base image so the erlang/otp version always matches
# ponytail: costs a few MB over a bare erlang image, avoids version drift
FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine
WORKDIR /app
COPY --from=build /build/build/erlang-shipment .
ENV PORT=4100
EXPOSE 4100
# gleam 1.18's entrypoint.sh has no shebang line, so invoke sh explicitly
ENTRYPOINT ["/bin/sh", "/app/entrypoint.sh"]
CMD ["run"]
