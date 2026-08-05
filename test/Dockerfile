# Throwaway test environment for probeprint2.
#
# Single container: MariaDB server runs in-container so the test suite can
# exercise the real SQL the scripts emit, and tshark is present so the ingest
# parser can be tested against real tshark field output rather than a mock.
#
# There is deliberately no network access to WiGLE or Nominatim from the test
# suite -- see fixtures/locs/ for the canned API bodies used instead.
FROM debian:bookworm

# DEBIAN_FRONTEND stops tshark's dumpcap-setuid debconf prompt from hanging the build.
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        tshark \
        jq \
        xxd \
        bc \
        curl \
        procps \
        python3 \
        python3-scapy \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/probeprint2

# The repo is copied in rather than bind-mounted so a test run can never write
# back into the working tree.
COPY . /opt/probeprint2/

ENTRYPOINT ["/opt/probeprint2/test/entrypoint.sh"]
CMD ["/opt/probeprint2/test/run_tests.sh"]
