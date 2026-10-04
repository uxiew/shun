# 测试专用：一个镜像按 ROLE 环境变量扮演 sshd 或 SOCKS5 代理。不要拿来跑任何真实服务。
FROM alpine:3.22
# vim、less、htop、tmux：终端引擎的全屏程序测试（TER03，R17 起）要真程序，不只拿转义序列模拟。
RUN apk add --no-cache openssh-server dante-server vim less htop tmux ncurses-terminfo-base
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
