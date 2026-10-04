# 测试专用：OpenSSH + 官方 mosh-server（Alpine 打包的 mosh 1.4.0）。X08 用它验证 Mosh 运行时的互操作。
# 不要拿来跑任何真实服务。vim、less：看全屏程序经 Mosh 重绘后对不对。
# mosh-client + tmux：在容器里跑官方客户端、用 tmux 抓它画出的屏幕，当作「官方客户端看到什么」的对照。
FROM alpine:3.22
RUN apk add --no-cache openssh-server mosh-server mosh-client tmux vim less ncurses-terminfo-base
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
