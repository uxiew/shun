# 测试专用：OpenSSH + 官方 mosh-server（Alpine 打包的 mosh 1.4.0）。X08 用它验证 Mosh 运行时的互操作。
# 不要拿来跑任何真实服务。vim、less：看全屏程序经 Mosh 重绘后对不对。
# mosh-client + tmux：在容器里跑官方客户端、用 tmux 抓它画出的屏幕，当作「官方客户端看到什么」的对照。
#
# PACKAGES 换掉就是另一台机器：compose 里的 nomosh 只装 openssh-server，当「服务器上没装 mosh」（X09 的 MOS02）。
FROM alpine:3.22
ARG PACKAGES="openssh-server mosh-server mosh-client tmux vim less ncurses-terminfo-base"
RUN apk add --no-cache $PACKAGES
COPY entrypoint.sh /entrypoint.sh
COPY shims/ /opt/xwshun-shims/
# 记账用的假命令放在 /usr/local/bin，sshd 给登录用户的 PATH 里它排在 /usr/bin 前面（up.sh 会核对）：
# - mosh-server：记一笔再原样交给真的（只有装了 mosh 的那台才有），用来数「远端启动了几次」；
# - sudo、apk、apt-get 等：只记一笔、返回失败，用来证明 App 没有替用户安装、没有 sudo。
# 在 apk add 之后才放进去，构建本身用的是真的 apk。
RUN chmod +x /entrypoint.sh /opt/xwshun-shims/* \
 && install -d -m 1777 /var/log/xwshun \
 && for c in sudo doas su apk apt apt-get yum dnf pacman zypper brew pkg; do \
      ln -s /opt/xwshun-shims/record-install "/usr/local/bin/$c"; \
    done \
 && if [ -x /usr/bin/mosh-server ]; then ln -s /opt/xwshun-shims/mosh-server /usr/local/bin/mosh-server; fi
ENTRYPOINT ["/entrypoint.sh"]
