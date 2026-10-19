# 基座决定（R00）

决定日期：2026-09-29，由项目所有者确认。

## 结论

| 项 | 决定 |
|---|---|
| 基座 | kmh1145/Netcatty-mobile，锁定 `495f5d3174d6b3825fc9edefa7ebe345f3399734`（tag `v1.4.7`，提交时间 2026-09-19） |
| 仓库位置 | 本机 `~/xdw/shun/shun`，分支 `shun/v3`；remote 只有 `origin` = `git@github.com:uxiew/shun.git`（2026-10-04 所有者定，当时是 `xwshun/netcatty-mobile`、`xwshun/v3`、`uxiew/xwshun`；2026-10-11 跟着 App 改名 shun）。**所有者说推之前不 push** |
| 许可 | GPL-3.0-or-later，**个人隔离实验**。对外分发（给任何其他人装）之前必须另做许可审核，见下文 |
| applicationId | `top.xdwa.shun`（所有者 2026-10-11 改名；R01 落地时是所有者指定的 `top.xdwa.xwshun`）。上游是 `app.netcatty.mobile`，不得复用 |
| 替代方案 | Conduit（Apache-2.0）不启用，不同时维护两条产品分支 |

## 锁定的输入

- 克隆时工作区干净（`git status` 无输出），上游 remote 名为 `upstream`，push 地址已改成无效值防手滑。2026-10-04 按所有者要求删掉了 `upstream`（连同它的远程分支引用），基座 `495f5d31` 仍在本分支历史里，本地 `main` 也还停在它上面。
- `pubspec.yaml` sha256 `528a0c909227faaf79d27bbc2bc9fef7d082b0996b29ffe05336da0c1ae3377a`
- `pubspec.lock` sha256 `ad69d656445fa16606c1ee962c1b7cad25b1f4724885ef5263776490af5a1140`，lock 要求 Dart ≥3.12.0、Flutter ≥3.44.0
- Flutter SDK：3.44.4 stable，取自上游 CI（`.github/workflows/mobile.yml`），装在仓库外 `../.toolchain/flutter`
- 上游版本号 `1.4.7+26`。**版本号不是锁定依据，SHA 才是**：上游以后往 main 推新提交不会影响本 fork。

以后要同步上游：不再常驻 upstream remote，临时拉指定提交——`git fetch https://github.com/kmh1145/Netcatty-mobile.git <SHA>`，再显式 merge 这个 SHA，并在本文件追加一行记录，不跟随浮动的 main。

## 许可义务：现在要做的和分发前要做的

说白了：GPL 不禁止你自己改着用；它约束的是"把改过的程序给别人"那一刻。

**现在（个人实验）就做：**

- 保留 `LICENSE` 原文不动。
- 根目录 `NOTICE.md` 写明原作者、上游来源、本 fork 修改过以及日期（GPL-3.0 第 5(a) 条要求修改版显著标注）。
- 不把任何上游代码复制到别的仓库后改标 Apache/MIT；插件做成独立 APK 也**不会**自动绕开 GPL（见 `plan/v3/docs/15-plugin-architecture.md`）。

**分发前（哪怕只发给一个朋友）必须补齐，否则不许发：**

- 随 APK 提供对应源码或书面源码提供方式。
- 上游 `LICENSE` 只有 11 行 GPL 声明，不含完整 GPL-3.0 正文，也没有版权行。分发包里要附完整 GPL-3.0 文本。
- `assets/distro/*.svg` 和 `assets/docker/*.svg` 是各发行版/产品的商标图标，上游没写来源和授权。分发前逐个核实，不能核实的换掉。
- 生成全部依赖（pub 包、native `.so`、Ghostty 预编译库）的许可清单，确认与 GPL-3.0 兼容。对应用例 BAS04 / REL01 / SDK02。

## 撞墙时

- `git push` 报 `Permission denied (publickey)`：remote 写的是 `git@github.com:uxiew/shun.git`，ssh 会拿默认钥匙去连，本机没有对 `github.com` 生效的钥匙。uxiew 的钥匙配在 `~/.ssh/config` 的 `github.com-uxiew` 别名下，推的时候用 `git@github.com-uxiew:uxiew/shun.git`（`ssh -T git@github.com-uxiew` 回 `Hi uxiew!` 就对了）。gh 登录的 xwfe 对这个仓库只有读权限，换成 HTTPS 经 gh 推会被拒。推送等所有者自己来。
- 如果以后决定不接受 GPL 分发条件：不能在本 fork 上改许可证。要另起 Conduit 基座并写替代 ADR（`plan/v3/docs/11-conduit-alternative.md`），本 fork 的代码不能搬过去。
