#!/usr/bin/env bash
# 停掉 TER13 的测试容器，删掉临时密码和主机密钥。镜像留着（下次 up 不用重新下 npm 包），要删：docker rmi shun-ai-cli:local
set -euo pipefail
cd "$(dirname "$0")"
docker rm -f shun-ai-cli >/dev/null 2>&1 || true
rm -rf .run
