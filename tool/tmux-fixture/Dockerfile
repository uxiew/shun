# 测试专用：一台 sshd + 指定 Alpine 版本自带的 tmux。不要拿来跑任何真实服务。
# Alpine 版本决定 tmux 版本（arm64 上能拿到的）：3.6→2.4、3.8→2.7、3.11→3.0a、3.22→3.5a。
ARG ALPINE=3.22
FROM alpine:${ALPINE}
RUN apk add --no-cache openssh-server tmux
COPY entrypoint.sh fake-tmux.sh /
RUN chmod +x /entrypoint.sh /fake-tmux.sh
ENTRYPOINT ["/entrypoint.sh"]
