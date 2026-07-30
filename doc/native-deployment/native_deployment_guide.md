# SightHouse Native Deployment Guide

This document outlines the architecture, configuration, and connection details for the fully native deployment of the SightHouse pipeline and BSim server. All components have been deployed without root privileges and without Docker.

## Architecture Overview

The native deployment mimics the containerized version but substitutes Docker networks and containers for user-space services. 

- **Object Storage**: Bypassed. Artifacts are exchanged between workers via the native `local://` scheme targeting `$HOME/sighthouse-native/artifacts`.
- **Message Broker**: Redis runs as a user-space daemon on port **63799**.
- **BSim Database**: A standalone PostgreSQL instance, compiled from source with the Ghidra BSim C-extension, runs natively on port **54322**.
- **Workers**: Git Scrapper, Autotools Compiler, CMake Compiler, and Ghidra Analyzer run in the background via `nohup` inside a Python virtual environment.
- **Frontend Server**: The REST API runs natively and serves the interface for SRE clients.

## Deployment Details

The entire environment was bootstrapped using an automated script located at:
[deploy_sighthouse.sh](deploy_sighthouse.sh)

### Directories
- **Base Directory**: `$HOME/sighthouse-native`
- **Database Data**: `$HOME/sighthouse-native/pgdata`
- **Redis Data**: `$HOME/sighthouse-native/redis`
- **Artifacts**: `$HOME/sighthouse-native/artifacts`
- **Logs**: `$HOME/sighthouse-native/logs`

### Pipeline Recipe

The automated deployment has submitted a pipeline recipe ([pipeline.yml](pipeline.yml)) into the Celery task queue to process standard C libraries and open source packers.

**Targets configured for compilation and BSim analysis**:
- `glibc` (`glibc-2.25.90` branch via `git://sourceware.org/git/glibc.git`) built with GCC Autotools.
- `upx` (`v4.2.4` branch via `https://github.com/upx/upx.git`) built with CMake.

The workers will continuously process these in the background. Expected completion time for `glibc` is approximately 30-40 minutes depending on hardware.

---

## Instructions for Analysts

Analysts can consume the generated signatures in two ways: by querying the BSim PostgreSQL database directly using Ghidra, or by querying the SightHouse Frontend REST API using the client plugins.

### 1. Connecting via Ghidra (Direct BSim)
If analysts are using the Ghidra UI and wish to connect natively to the BSim server:
1. Open Ghidra.
2. Navigate to **BSim -> Manage Servers**.
3. Add a new server with the following details:
   - **Type**: `PostgreSQL`
   - **Host**: Address of this machine (or `localhost` if running locally).
   - **Port**: `54322` (Note the custom port to avoid conflicts with system Postgres).
   - **Database**: `bsim`
   - **User**: `<YOUR_USERNAME>` (or the username of the user who deployed it).

### 2. Connecting via SightHouse Client Plugins
SightHouse provides client plugins for IDA, Ghidra, and Binary Ninja that abstract the queries through the frontend API.
- The frontend server is running on port **8080**.
- Analysts should configure their respective plugins to point to `http://<server-ip>:8080`.
- The frontend will handle translating the requests and querying the underlying `bsim` database.
