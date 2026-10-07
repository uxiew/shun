# TER13（R20）：在真 PTY 里跑 Claude Code、Codex CLI 的交互界面。只用来测终端，不登录任何账号、不放任何凭据。
# 所有者 10-07 定只走不登录就能看到的界面（选主题、选登录方式、Ctrl+C 中断），流式输出要登录、不测。
FROM node:22-bookworm-slim

# 两个 CLI 的版本在构建时固定下来，写进镜像的 /versions.txt，证据里照抄。换版本：改这两个参数重新 up。
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server ca-certificates tmux less locales \
 && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g --no-fund --no-audit \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
 && { echo "node $(node --version)"; \
      echo "claude-code $(npm ls -g --depth=0 @anthropic-ai/claude-code | grep -o 'claude-code@[^ ]*')"; \
      echo "codex $(npm ls -g --depth=0 @openai/codex | grep -o 'codex@[^ ]*')"; } > /versions.txt \
 && cat /versions.txt

RUN useradd -m -s /bin/bash fixture \
 && mkdir -p /run/sshd \
 && printf '%s\n' \
      'PasswordAuthentication yes' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers fixture' > /etc/ssh/sshd_config.d/fixture.conf \
 # 少发网络请求：不自动更新、不上报。两个 CLI 都没有账号，能做的只有展示界面。
 && printf '%s\n' \
      'export LANG=en_US.UTF-8' \
      'export DISABLE_AUTOUPDATER=1' \
      'export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' \
      'export DISABLE_TELEMETRY=1' >> /home/fixture/.profile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
