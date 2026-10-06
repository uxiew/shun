#!/usr/bin/env bash
# 停掉容器并删除本次生成的全部临时凭据。只动 xwshun-mosh 这个 compose 项目。
set -euo pipefail
cd "$(dirname "$0")"
docker compose down --remove-orphans --volumes
rm -rf .run
