#!/bin/bash
# Bring up MariaDB inside the test container, bootstrap the probeprint schema,
# then hand off to whatever command was passed (run_tests.sh by default).
set -euo pipefail

REPO=/opt/probeprint2
cd "$REPO"

echo "== starting mariadb =="

# The mariadb-server postinst normally initialises /var/lib/mysql, but that is
# not guaranteed to have run in a container build, so do it idempotently.
if [ ! -d /var/lib/mysql/mysql ]; then
    mariadb-install-db --user=mysql --auth-root-authentication-method=socket >/dev/null
fi

mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
mysqld_safe --skip-syslog >/tmp/mariadb.log 2>&1 &

# Wait for the socket rather than sleeping a fixed amount.
for _ in $(seq 1 60); do
    if mysqladmin ping >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! mysqladmin ping >/dev/null 2>&1; then
    echo "FATAL: mariadb did not come up" >&2
    tail -30 /tmp/mariadb.log >&2
    exit 1
fi
echo "mariadb up: $(mysql -N -e 'select version();')"

# The probeprint2 scripts all connect as `mysql probeprint` with no credentials,
# relying on unix_socket auth for the current user. We run as root, which
# MariaDB maps via unix_socket by default, so no grants are needed.

echo "== bootstrapping schema via build_dbs.sh =="
./build_dbs.sh

# .env is required by most scripts and is gitignored, so synthesise a test one.
# online=0 and a dummy APIKEY guarantee no script can reach WiGLE.
cat > "$REPO/.env" <<'ENV'
APIKEY=dummy:dummy
INF=lo
online=0
ENV

# Canned WiGLE responses stand in for the live API.
mkdir -p "$REPO/locs"
cp -f "$REPO"/test/fixtures/locs/*.location "$REPO/locs/" 2>/dev/null || true

# check_industry reads this list; gitignored, so provide a deterministic one.
mkdir -p "$REPO/lists"
[ -f "$REPO/lists/industry.txt" ] || printf 'acmecorp\ninitech\n' > "$REPO/lists/industry.txt"
[ -f "$REPO/lists/ignore.txt" ]   || : > "$REPO/lists/ignore.txt"

echo "== schema =="
mysql -N probeprint -e "show tables;" | sed 's/^/  /'

exec "$@"
