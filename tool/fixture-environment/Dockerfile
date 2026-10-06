# 测试专用：一个镜像按 ROLE 环境变量扮演 sshd 或 SOCKS5 代理。不要拿来跑任何真实服务。
FROM alpine:3.22
# vim、less、htop、tmux：终端引擎的全屏程序测试（TER03，R17 起）要真程序，不只拿转义序列模拟。
# bash：粘贴测试（R19）要真 readline 的 bracketed paste；登录 shell 仍是 busybox sh（它不支持 bracketed paste），测试里显式起 bash。
RUN apk add --no-cache openssh-server dante-server vim less htop tmux ncurses-terminfo-base bash
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
