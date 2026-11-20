# UI迁移规划证据（2026-11-05）

## 范围与真实状态

所有者F43要求只选一个主目标并形成可按阶段执行的移植任务。本次完成决策与计划，未执行R81–R98。没有修改App源码、pubspec/lock、终端引擎、用户数据；没有构建、运行或安装App，没有真机/账号操作，也未push/发布。

规划前：工作区shun，仓库 `shun/`（工具链工作区下），分支 `shun/v3`，HEAD `92fe59340515ac26db51cb3a18397d2f42e3c012`，工作区干净。实际提交以本记录的git历史为准，不伪造包含自身的提交号。

## 已读与结论

- 读取根/plan AGENTS及要求的V3契约、UI文案规范、实际app/HomeShell/测试目录；并行只读复核页面迁移地图、规划依赖约束和Prism集成。
- 当前入口实际是MaterialApp(home: HomeShell())，未使用go_router驱动主界面。五页IndexedStack、root navigatorKey、应用锁/生命周期继续保留。
- 固定FlClash `be84736605527034689c95bf27828ff27d912c5e`，GitHub submodule实际指向Prism `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`。官方原始资料S89–S102逐项记录在sources和docs/13；README、manifest、宿主/sheet/motion/banner/theme snapshot、LICENSE/NOTICE均直接读取。
- Prism 0.1.2的声明SDK下限满足本机手册，但没有实际求解/构建；不将其称为已在shun验证成熟。
- 直接PrismApp替换会让现有builder内锁罩位于Banner/ThemeCrossFade内；采用公开组件薄ShunUiHost的接入设计，不安装全应用截图主题过渡。此为源码推导的风险和设计，未声称已在设备复现或验证修复。
- 默认Prism sheet为模态；本方案保留F41真非模态。FormGap、短文案、独立帮助语义、F42无管理页及终端单view/输入/手势均进入任务与用例。

## 计划改动

新增六阶段GU0–GU5、R81–R98共18项和UIM01–UIM22共22项；详细任务含依赖、真实代码落点/明确新增文件、交付、验收、停止条件与test_ids。新增目标决策和docs/24，更新STATUS、交接、优先级、文档入口与F43记录。

R26只增加新候选R98前提及UIM22，仍IN_PROGRESS；R98不依赖R26/发布任务。R30继续直接依赖X13，并将test_ids校正到全部当前210项。旧95项任务状态/commit/evidence与旧188项用例结果/evidence保持不变；原G/GX门禁不变。docs/08中R79残留“管理页”描述按已有tasks.json/F42纠正，未重写其状态。

规划后应为：任务113（非P6 74、P6 39）；状态DONE 61/IN_PROGRESS 10/NOT_STARTED 23/DEFERRED 19。用例210：PASS 157/BLOCKED 6/NOT_RUN 47。来源102。

## 独立审查修正

三路只读审查核对了宿主公开API、任务/用例依赖与真实源码/测试。已补：WidgetsApp显式无截图根route工厂与关闭遥控焦点；秘密输入扫描器适配；测试连接/认证指纹/端口转发/协议切换等弹层的明确归属；非模态按背景可操作而非全树barrier为零判断；统一新增文件目录和用例JSON唯一权威；R26待测预期按F41/F42校正但不改结果。

## 校验

变更前已执行 `python3 scripts/validate_plan.py`（workdir plan/v3），exit 0：95任务、188用例、88来源、42旧任务映射、13 schema样例，passed=true；scope=PLANNING_FILES_ONLY、application_tests_executed=false。

变更后已实际执行（工作目录说明如下）：

| 检查 | 实际结果 |
|---|---|
| `python3 scripts/sync_docs.py`，workdir `plan/v3` | exit 0，synced；任务/用例可读副本状态同步 |
| `python3 scripts/validate_plan.py`，workdir `plan/v3` | exit 0，passed=true；113任务、74非P6/39P6、210用例、102来源、42旧任务映射、13 schema样例、errors=[] |
| 只读一致性核对，workdir仓库根 | 11项全部通过：旧任务状态/commit/evidence、旧用例结果/evidence、旧门禁保留；新项未执行；计数正确；R30全覆盖；R98无真机依赖；文件路径存在或明确新增；R81前提均DONE |
| `git diff --check`，workdir仓库根 | exit 0，无输出 |
| 独立只读审查与定向复核 | 宿主/第三方API、任务依赖/证据、源码/模块覆盖三路复核通过；上一轮必须修项均关闭 |

上述校验scope均为 **PLANNING_FILES_ONLY**，**application_tests_executed=false**。新增UI用例仍NOT_RUN，没有把任何规划检查记为App通过。后续仅补本记录和整理空行，不改变任务/用例定义。

## 未执行与下一项

没有新截图、性能测量、依赖解算、Flutter单测/构建、模拟器或真机证据。唯一下一项是R81，实际取基线后才能接入R82。正式签名/用户手机安装仍按既有当次授权；本次无该操作。原真实账号/硬件缺口保留，不自动启用R71/R80。
