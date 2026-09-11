ARG BASE=debian:12
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends bash bats shellcheck python3 jq curl ca-certificates tar gzip xz-utils procps iproute2 util-linux systemd systemd-sysv dbus sudo git && rm -rf /var/lib/apt/lists/*
WORKDIR /work
CMD ["bats", "tests/installer.bats"]
