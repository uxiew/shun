#!/usr/bin/env bash
# 停掉并删除这套容器（节点状态、Headscale 数据库都在容器里，一起删），删掉 .run 里的密钥和口令。镜像留着下次用。
set -euo pipefail
cd "$(dirname "$0")"
SERVER_AUTHKEY=x SOCKS_AUTHKEY=x ORDINARY_PASSWORD=x docker compose down --remove-orphans
rm -f ../.run/headscale.env ../.run/headscale.json
