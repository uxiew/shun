# 测试专用：一个镜像按 ROLE 环境变量扮演 sshd 或 SOCKS5 代理。不要拿来跑任何真实服务。
FROM alpine:3.22
RUN apk add --no-cache openssh-server dante-server
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
