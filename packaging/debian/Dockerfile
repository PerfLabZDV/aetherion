# The build environment of the Debian 13 package: Debian's own Erlang and Elixir,
# so the release links against the libraries of the servers it runs on.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

# erlang-dev for native dependencies; cmake, git, curl and perl for quicer, which
# emqtt pulls in; dpkg-dev for dpkg-shlibdeps.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      elixir erlang-nox erlang-dev \
      build-essential cmake git curl perl ca-certificates dpkg-dev file \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force
