#!/bin/bash
set -e

# Default values
BASE_DIR="$HOME/sighthouse-native"
GHIDRA_DIR="/opt/ghidra/ghidra_12.0.4_PUBLIC"
SIGHTHOUSE_SRC="$HOME/github/sighthouse"
PG_PORT=54322
REDIS_PORT=63799
REDIS_BIN="redis-server"

# Usage help
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --base-dir DIR         Base directory for deployment (default: $HOME/sighthouse-native)"
    echo "  --ghidra-dir DIR       Path to Ghidra installation (default: /opt/ghidra/ghidra_12.0.4_PUBLIC)"
    echo "  --sighthouse-src DIR   Path to SightHouse source repository (default: $HOME/github/sighthouse)"
    echo "  --pg-port PORT         PostgreSQL port (default: 54322)"
    echo "  --redis-port PORT      Redis port (default: 63799)"
    echo "  --redis-bin PATH       Path to redis-server executable (default: searches PATH, then ./bin/redis-server)"
    echo "  -h, --help             Show this help message"
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --base-dir) BASE_DIR="$2"; shift ;;
        --ghidra-dir) GHIDRA_DIR="$2"; shift ;;
        --sighthouse-src) SIGHTHOUSE_SRC="$2"; shift ;;
        --pg-port) PG_PORT="$2"; shift ;;
        --redis-port) REDIS_PORT="$2"; shift ;;
        --redis-bin) REDIS_BIN="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if [ "$REDIS_BIN" = "redis-server" ] && ! command -v redis-server &> /dev/null; then
    if [ -x "$BASE_DIR/bin/redis-server" ] && "$BASE_DIR/bin/redis-server" --version &> /dev/null; then
        REDIS_BIN="$BASE_DIR/bin/redis-server"
    elif [ -x "./bin/redis-server" ] && "./bin/redis-server" --version &> /dev/null; then
        REDIS_BIN="./bin/redis-server"
    fi
fi

build_redis() {
    echo "    Downloading and compiling Redis from source..."
    mkdir -p "$BASE_DIR/src"
    cd "$BASE_DIR/src"
    if [ ! -f "redis-stable/src/redis-server" ]; then
        if [ ! -f "redis-stable.tar.gz" ]; then
            wget -q https://download.redis.io/redis-stable.tar.gz
        fi
        if [ ! -d "redis-stable" ]; then
            tar -xzf redis-stable.tar.gz
        fi
        cd redis-stable
        echo "    Running make (this takes about 1-2 minutes)..."
        make BUILD_TLS=no MALLOC=libc > ../make-redis.log 2>&1 || {
            echo "[-] Error: Redis compilation failed! Check $BASE_DIR/src/make-redis.log for details."
            exit 1
        }
        cd ..
    fi
    REDIS_BIN="$BASE_DIR/src/redis-stable/src/redis-server"
    echo "    Successfully built Redis at $REDIS_BIN"
    cd "$BASE_DIR"
}

if ! command -v "$REDIS_BIN" &> /dev/null && [ ! -x "$REDIS_BIN" ]; then
    echo "    redis-server not found or not executable."
    build_redis
elif ! "$REDIS_BIN" --version &> /dev/null; then
    echo "    $REDIS_BIN is corrupted or built for a different architecture."
    build_redis
fi

echo "[+] Starting Native SightHouse Deployment"
echo "    Base Directory: $BASE_DIR"
echo "    Ghidra Directory: $GHIDRA_DIR"
echo "    SightHouse Source: $SIGHTHOUSE_SRC"

mkdir -p "$BASE_DIR"/{redis,pgdata,artifacts,logs}
cd "$BASE_DIR"

echo "[+] Building BSim PostgreSQL extension..."
BSIM_SUPPORT="$GHIDRA_DIR/Ghidra/Features/BSim/support"

if [ ! -d "$BSIM_SUPPORT" ]; then
    echo "[-] Error: BSim support directory not found at $BSIM_SUPPORT"
    echo "    Please verify your Ghidra installation path."
    exit 1
fi

if [ ! -d "$GHIDRA_DIR/Ghidra/Features/BSim/build/os/linux_x86_64/postgresql" ] && [ ! -d "$GHIDRA_DIR/Ghidra/Features/BSim/build/os/linux64/postgresql" ]; then
    echo "    Patching make-postgres.sh to disable readline requirement..."
    sed -i 's/POSTGRES_CONFIG_OPTIONS="--disable-rpath --with-openssl"/POSTGRES_CONFIG_OPTIONS="--disable-rpath --with-openssl --without-readline"/' "$BSIM_SUPPORT/make-postgres.sh"
    echo "    Running make-postgres.sh (this may take a few minutes)..."
    bash "$BSIM_SUPPORT/make-postgres.sh" > logs/make-postgres.log 2>&1
else
    echo "    PostgreSQL already built."
fi

PG_BIN=$(find "$GHIDRA_DIR/Ghidra/Features/BSim/build/os" -type d -path "*/postgresql/bin" | head -n 1)
if [ -z "$PG_BIN" ]; then
    echo "[-] Error: PostgreSQL binaries not found. make-postgres.sh likely failed silently."
    echo "    Check logs/make-postgres.log for details."
    exit 1
fi
PG_LIB="$(dirname "$PG_BIN")/lib"
export LD_LIBRARY_PATH="$PG_LIB:$LD_LIBRARY_PATH"
export PATH="$PG_BIN:$PATH"

echo "[+] Initializing PostgreSQL..."
if [ ! -f "$BASE_DIR/pgdata/PG_VERSION" ]; then
    initdb -D "$BASE_DIR/pgdata" > logs/initdb.log 2>&1
    # Change port to avoid conflicts
    echo "port = $PG_PORT" >> "$BASE_DIR/pgdata/postgresql.conf"
fi

echo "[+] Starting PostgreSQL server on port $PG_PORT..."
pg_ctl -D "$BASE_DIR/pgdata" -l logs/postgres.log start || true
sleep 3
# Create database (ignore if already exists)
createdb -h localhost -p "$PG_PORT" bsim || true

echo "[+] Starting Redis on port $REDIS_PORT..."
"$REDIS_BIN" --port "$REDIS_PORT" --dir "$BASE_DIR/redis" --daemonize yes --logfile "$BASE_DIR/logs/redis.log" || true

echo "[+] Installing SightHouse packages..."
if [ ! -d "$SIGHTHOUSE_SRC" ]; then
    echo "[-] Error: SightHouse source directory not found at $SIGHTHOUSE_SRC"
    exit 1
fi

cd "$SIGHTHOUSE_SRC"
if [ ! -d "venv" ]; then
    make install > "$BASE_DIR/logs/make-install.log" 2>&1
fi
source venv/bin/activate

echo "[+] Starting SightHouse Workers..."
export REDIS_URL="redis://localhost:$REDIS_PORT/0"
export ARTIFACTS_URL="local://$BASE_DIR/artifacts"

nohup sighthouse package run -i -f GitScrapper -w "$REDIS_URL" -r "$ARTIFACTS_URL" > "$BASE_DIR/logs/scrapper.log" 2>&1 &
nohup sighthouse package run -i -f AutotoolsCompiler -w "$REDIS_URL" -r "$ARTIFACTS_URL" > "$BASE_DIR/logs/autotools.log" 2>&1 &
nohup sighthouse package run -i -f CmakeCompiler -w "$REDIS_URL" -r "$ARTIFACTS_URL" > "$BASE_DIR/logs/cmake.log" 2>&1 &
nohup sighthouse package run -i -f GhidraAnalyzer -w "$REDIS_URL" -r "$ARTIFACTS_URL" -g "$GHIDRA_DIR" > "$BASE_DIR/logs/analyzer.log" 2>&1 &

if [ -f "$BASE_DIR/pipeline.yml" ]; then
    echo "[+] Waiting for workers to initialize before submitting recipe..."
    sleep 5
    echo "[+] Submitting Pipeline Recipe..."
    sighthouse pipeline -w "$REDIS_URL" -r "$ARTIFACTS_URL" start "$BASE_DIR/pipeline.yml" > "$BASE_DIR/logs/submit.log" 2>&1
else
    echo "[-] Warning: $BASE_DIR/pipeline.yml not found. Skipping recipe submission."
fi

echo "[+] Starting Frontend Server..."
nohup sighthouse frontend run --db "postgresql://$USER@localhost:$PG_PORT/bsim" --port 8080 > "$BASE_DIR/logs/frontend.log" 2>&1 &

echo "[+] Deployment complete! All services are running in the background."
