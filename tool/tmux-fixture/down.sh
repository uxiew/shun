#!/usr/bin/env bash
# 停掉 R21 的 tmux 测试容器并删除本次生成的全部临时凭据。不碰 tool/fixture-environment 那一套。
set -euo pipefail
cd "$(dirname "$0")"
docker compose down --remove-orphans --volumes
rm -rf .run
