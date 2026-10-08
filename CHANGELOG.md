# Changelog

本仓库为第三方三改版本，在上游 AlwaysStrong-OMK（二改）基础上继续维护；版本号沿用上游 AlwaysStrong 的 `v1.0.x` 并加 `-omk-rN` 后缀。自 `v1.0.6-omk-r1` 起重新起版，下方保留二改的 `v1.0.4-omk-r*` 历史。

> **历史停维说明（2026-09-30）：公开镜像的 keybox 大规模被吊销，本仓库一度暂停维护。**
> 自 r11 起恢复维护：条件材料改由新的上游来源提供，不再依赖那个已被吊销的镜像。
> 下面 r9 / r10 两段保留作记录，其中 r10 的 `vb_hash` / `vb_key` 钉值通道**未经真机验证**。

## v1.0.6-omk-r1 — 2026-10-08

三改重新起版：撤回 yypm 的 WebUI 与组件商店移植，同时保留其多源 keybox 分发。

### 变更

- **WebUI 恢复为 OMK 原版**：撤回 yypm 界面的整套移植，`module/webroot/index.html` 换回 OMK 自带界面，
  其后端（`engine.sh` / `attest.sh` / `status_fetch.sh` 等）一并恢复。
- **移除组件商店及相关分发**：删除 yypm 组件（Zygisk-Next / HMA-OSS / FuseFixer）、组件注册表
  `packages/sources.json`、`scripts/gen-packages.py`，以及签名式自更新（`self_update.sh` +
  `native/verifier`）。
- **保留 yypm 多源 keybox 分发**：`module/keybox_sources.sh`（移植 yypm `php-server/lib/sources.php`）
  继续随包分发——yurikey / integritybox / megatron 优先，keyboxhub / keyboxstatus 目录轮换兜底，
  按优先级 + 吊销过滤择优；`keybox_fetch.sh` 走该池，`keybox_revoke_check.sh` / `status_fetch.sh`
  使用多镜像吊销名单（purainity / KimmyXYC 优先，Google 官方兜底）。
- **指纹来源换回上游原生抓取**：由 `Elcapitanoe/PIF-Config-Generator` 的 release feed 撤回为
  `flash.android.com` + `content-flashstation-pa.googleapis.com` 的原生抓取（即 r10 行为）。
- 保留 r11 的证明引擎 **OhMyKeymint 1.3.5-196-10113e7**、可选 Soter 中继与本地推导健康状态。

**Bundled in every build of this release**
- Keystore: OhMyKeymint `v1.3.5-196-10113e7`
- Play Integrity: PlayIntegrityFork `v18`

## v1.0.4-omk-r11 — 2026-10-08

恢复维护。本版把三处外部来源全部换掉，并补上 Qualcomm Soter 中继。

### 变更

- **证明引擎升级**：`OhMyKeymint 1.2.0-preview-a1f3241` → `1.3.5-196-10113e7`
  （[ITxiao6666/OhMyKeymint](https://github.com/ITxiao6666/OhMyKeymint) 分支，**非官方版本**）。
  只取 keystore 引擎部分：`libs/arm64-v8a/{keymint,inject,soterta-svc}`、`injector.toml`、
  `soterta.sh`；OMK 自带的 zygisk、`webroot/`、`daemon/` 一律不要，骨架仍用本仓库原有实现。
- **keybox 默认来源**换成 [ZeyolZZZ/TEESimulator-RS-fix](https://github.com/ZeyolZZZ/TEESimulator-RS-fix)
  的 `module/keybox.xml`；`keybox_fetch.sh` 现在同时接受 XML 与 base64 两种载荷（按首字节判断），
  并支持 `KEYBOX_URL`（整份）/ `KEYBOX_BASE_URL`（`<root>/key`）覆盖。
- **指纹来源**改为 [Elcapitanoe/PIF-Config-Generator](https://github.com/Elcapitanoe/PIF-Config-Generator)
  的 release feed：取最新**稳定**（asset 名不含 `_beta_`）的 Pixel 档案，优先按设备代号匹配，
  优先序 `caiman komodo tegu comet frankel blazer felix husky`（`tokay` 已排除，Google 撤销了它的
  STRONG）。feed 缓存 6 小时（`$CONFIG_DIR/.pif_feed.json`）。失败时回退到上游 `autopif4.sh`，
  再回退到内置的两份 `.prop`。
- **状态行改为本地推导**：删除对 `http://evoker.qzz.io/status` 与 `/meta.json` 的依赖（该镜像
  提供的是另一份 keybox，与默认来源不是同一个）。现在三段信号各自本地计算：
  `keybox_check.sh`（结构）、`attest_alive`（引擎存活）、`keybox_revoke_check.sh`（对缓存下来的
  Google 吊销名单做比对，`$CONFIG_DIR/.kb_status_list`，缓存 24 小时）。被吊销但结构合法的 key
  呈现 `🟢🟢🔴`，被拒绝的 key 呈现 `🔴🔴🟡`。
- **Soter 中继（可选）**：随包提供 `soterta.sh` + `libs/<abi>/soterta-svc`，服务
  `vendor.qti.hardware.soter.ISoter/default`。默认**关闭**，只有显式写入启用标记后才启动；
  `attest/omk.sh` 的 `attest_start` 会在每轮看护里把它拉起，`omk-early.sh` 准备
  `/data/misc/keystore/omk/data/soterta`（0770，uid 1017）。
- `keybox_check.sh` 放宽为接受**纯 EC** 的 keybox（引擎 `keybox.rs` 同时接受 dual / RSA-only /
  EC-only），错误信息改为 `no <Key algorithm="rsa"> or <Key algorithm="ecdsa"> entry`。
- `collect_logs.sh`、`webroot/index.html` 去掉镜像相关字段：keybox 名称直接读本地
  `DeviceID="..."`，日志探针指向真实 keybox 主机。

### 验证

- 离线：`keybox_check.sh` 对 ZeyolZZZ 与 OMK 自带的 keybox 均 rc=0，缺文件 rc=2，
  纯 EC 合成样本 rc=0，无证书 rc=1。
- 吊销比对：用 ZeyolZZZ 的叶证书序列号构造合成名单，`REVOKED` 命中 rc=1 并打印
  `serial=` / `reason=`，`SOON` 与无关序列号 rc=0。
- 指纹：以真实 feed 跑通 `pif_native_fetch.sh`，选中 `Komodo_CP3A.260905.009.json`
  （tag `v2026.09.20`），经 PlayIntegrityFork `migrate.sh` 生成完整 `custom.pif.prop`。
- 构建：`build.sh --omk-file` 产出 12 MB 包，含 `soterta.sh`、
  `libs/arm64-v8a/{keymint,inject,soterta-svc}`、`injector.toml`、`keybox.xml`。
- 未在真机上验证：Soter 中继的实际握手、`vb_hash` / `vb_key` 钉值通道（沿用 r10 说明）。

## v1.0.4-omk-r10 — 2026-09-30

停维前最后一版。

r9 刷入后设备侧验证通过：两道 keybox 闸门真的生效了（`usable-by-keymint: yes` /
`revoked-by-google: no`），keybox 已换成未吊销那份 —— 但 DEVICE 与 STRONG 仍然红。关键路径因此从
"身份材料"转向"被证明的引导完整性"。本版本含两项行为改动（`[trust]` 的 `vb_hash` / `vb_key` 钉值通道、
删除 `service.sh` 伪造 digest）与三项诊断，**均未在真机上验证过**。

### 新增

- `collect_logs.sh`：`--- verified boot inputs` 段。把 `ro.boot.vbmeta.digest`、
  `ro.boot.vbmeta.public_key_digest`、`ro.boot.verifiedbootstate`、`ro.boot.vbmeta.device_state`
  并排打出来，并**复算 `sha256(vbmeta 分区前 64 KiB)`** 与 digest 比对：两者相等即证明 attestation 里的
  `VerifiedBootHash` 是 `service.sh` 编造的数，而不是 AVB 度量的摘要。这四个数此前分散在三个文件里，
  把它们对齐花掉了一整轮排查。
- `collect_logs.sh`：Module 段新增 `scripts fingerprint`（对模块目录下所有 `.sh` 做
  `sha256sum | sha256sum` 取前 8 位，含文件名，所以改名/增删/改内容都会让它变）。同一个 `version=`
  可以对应两份不同的包，这行回答的是"设备上实际是哪份字节"，比版本号可靠。
- `collect_logs.sh`：`--- level-zero key selection` 段（r9 排查丢库时加的，随本版本出货）。
- `omk-sync.sh`：`[trust]` 写入器新增 **`vb_hash` / `vb_key` 钉值**。放两个文件
  `/data/adb/tricky_store/vb_hash`、`/data/adb/tricky_store/vb_key`（各恰好 64 位十六进制）即写入
  config.toml 并触发 keymint 重启；文件缺失或格式不对时**一律不动这两个键**并在 stderr 说明。
  这是引擎文档化的路径（`a 64-character hexadecimal string pins an exact value`），比伪造
  `ro.boot.vbmeta.*` 属性干净——那两个属性真 keystore2 也在读。已测：无覆盖文件时输出与输入
  逐字节相同（不会白白重启 keymint），重复钉同一值幂等。

### 说明

- **`service.sh` 里伪造 digest 的那段已删除（2026-10-04）**。原公式是错的：AVB 的 vbmeta digest
  是对 vbmeta **结构体**（header + descriptors + auxiliary，长度通常只有几 KB）算的，不是对分区前
  64 KiB 原始字节算的，而输出同样是 64 位十六进制，所以从日志上看不出问题。引擎的
  `vb_hash = "auto"` 读的正是这个属性（二进制里能看到它读 `ro.boot.vbmeta.digest` 与
  `ro.boot.vbmeta.public_key_digest`），于是这段兜底会把"真值缺失"伪装成"有一个看着合理的根信任"。
  注意它**不是本次的病因**：设备上的 `5e44f8ea…` 实测等于 `sha256(该 ROM 的 vbmeta.img 前 6656 字节)`，
  是内核报的真摘要，这段兜底当时并未触发。删掉后属性保持内核给的值，缺值由 `collect_logs.sh` 的
  `WARN: no vbmeta digest` 直接暴露；`collect_logs.sh` 仍复算那个旧公式作对照，万一更早安装的版本
  留下过伪造值、或有人把它加回来，那行 WARN 会认出来。
- `ro.boot.vbmeta.public_key_digest` 引擎会读，但模块从不设置；`omk-sync.sh` 的 `[trust]` 写入器只
  覆盖 7 个键，`vb_hash`/`vb_key` 不在其中 —— 也就是说这两个键从来没被本模块管过。现已补上钉值支持。
- **病因（当前唯一被证实的解释）**：测试机刷的是自定义 ROM，其 `vbmeta.img` **没有认证块**（描述符
  紧跟 256 字节头，即无 hash / 签名 / 公钥）。OMK 如实上报"一个未签名 vbmeta 的正确摘要"，这样的
  摘要不属于任何已认证构建，所以 DEVICE 拿不到。要改的是**同构建官方签名镜像**的摘要，工具见
  `tools/avb_digest.py`（已用本机这份 vbmeta 反向验证过边界公式）。
- **`security_level.rs:404` 与 B 键那条线已结案为噪声**：取到完整 `Caused by` 链后，34 个错误块里
  20 个是兼容性测试 app 的参数探测被拒（`-11 INCOMPATIBLE_PADDING_MODE`、`-3 INCOMPATIBLE_PURPOSE`、
  `-21 INVALID_INPUT_LENGTH`，别名 `ChallengeLenTest_*` / `AttestClosure*_*` / `cq_tee_mixed_*`），
  12 个是**锁屏状态**下访问 UnlockedDeviceRequired 密钥（`super_key.rs:903 Device is locked`、
  `-26 KEY_USER_NOT_AUTHENTICATED`）。与 Play 判定无关。
- 顺带修正一处此前写错的注释：`omk-sync.sh` 原话说四个 patchlevel 字段的 `auto` 都读构建属性，实际
  `boot_patchlevel` 读的是**顶层 vbmeta 里的 `com.android.build.boot.security_patch`**（引擎
  `docs/CONFIGURATION.md` 确认），所以日志里 `boot_patchlevel 20260901` 与属性 `2026-08-05` 不一致
  是设计如此，不是缺陷。
- 本轮排除的两条：**keybox**（链已验证为 Google 签发、未吊销、`T=TEE`、`Verified`、
  `deviceLocked: true`，且设备上呈现的三张证书与装上的那份 keybox 逐张对上）；**私有存储每次开机
  重建**（是真缺陷，但 20:11 那次在库自 19:24 起完好时 DEVICE 仍红，故不阻塞判定）。
- 版本号从 r9 升到 r10 的取舍：r9 从未提交也未发布，本可沿用同号；选升号是因为 r10 动的是另一个
  子系统，同号会让"哪次刷入对应哪个改动"重新变糊。

## v1.0.4-omk-r9 — 2026-09-30

r8 已经把两道 keybox 校验写进了代码，设备上的诊断却仍然报 `keybox_check.sh not installed`。
本次接上这条断掉的路，并修掉吊销校验里一处解析缺陷。顺带定案：**设备上那份 keybox 确实已被
Google 吊销**，r8 记录里的相反结论作废。

### 修复

- **`customize.sh` 的解压白名单漏列两个校验脚本**。`keybox_check.sh` 其实一直在 r8 的 zip
  里，但 `for f in ...` 那个清单没有它，安装时从不被解压到 `$MODPATH`；
  `keybox_revoke_check.sh` 当时还是未跟踪文件，根本没进包。后果是设备侧两道闸同时退化 ——
  `collect_logs.sh` 报 `usable-by-keymint: unknown (keybox_check.sh not installed)`，而
  `keybox_fetch.sh` 因为 `$SELF_DIR/keybox_check.sh` 不存在，回落到
  `grep "Keybox"` 这个字符串兜底（它 `elif` 那条分支），一份畸形 keybox 又能走到落盘那一步。
  现在两个脚本都在清单里，权限由 `build.sh` 既有的 `chmod 0755 "$STAGE"/*.sh` 覆盖。
- **`keybox_revoke_check.sh` 的 `reason=` 恒为字面量 `REVOKED`**，从没取出过 Google 给的
  真实原因。列表是缩进 JSON：序列号占一行，`status` 与 `reason` 在其后几行，而原先
  `grep -m1` 只拿到序列号那一行，随后两个 `sed` 必然落空，最后回落到 `_reason=REVOKED`。
  现在先 `tr -d '\n\r\t'` 把列表展平一次，再整段匹配 `"<serial>" : { ... }`，两个字段都如实
  取出（每条记录对象内没有嵌套花括号，`[^}]*` 就到得了结尾）。
- 同一处改为**只认 `status=REVOKED`**。旧写法只要序列号在册就判命中，而
  `?includeExpired=true` 端点（本项目备用链接之一，`KEYBOX_STATUS_URL` 可覆盖）里还有
  `EXPIRED`、`SOON` 这类状态，于是会把一份当下仍然可用的 key 判死，`keybox_fetch.sh` 随之
  拒装。现在非 `REVOKED` 一律跳过；只有在册却读不出 `status` 字段的才按吊销处理（保守）。

### 变更

- `module/keybox_check.sh`、`module/keybox_revoke_check.sh` 首次纳入版本控制并随模块出货。
- `module/collect_logs.sh` 新增两段诊断：
  - keybox 回退：抓 keymint 日志里的 `invalid keybox` / `rewriting bundled template` /
    `fallback=true` / `missing RSA key entry`，并把运行时目录与配置目录两份 keybox 的
    sha256 对比 —— 两者不一致说明 keymint 读的不是用户以为装上的那份。
  - 吊销结论：`revoked-by-google: yes/no/unknown`，命中时逐条列出序列号与原因；列表取不到
    时明确报 `unknown`，不当成「没吊销」。
- `build.sh`：新增出货前的**装机覆盖断言**。把 `customize.sh` 的 `for f in ...` 清单
  （其中 `$ENGINE_FILES` 按 customize.sh 的方式从 `engine.sh` 取出）、两处字面量
  `install_file "..."` 调用一起还原成「安装器会要哪些文件」，然后双向核对：模块根目录每个
  `.sh` 都必须被某个安装器要过，清单里点的名字也必须在暂存目录里真的存在，否则 `die` 并列出
  具体文件。r8 那个「文件在包里、却没人解压」的 bug 属于静默失效，只能从设备日志反推，现在
  打包阶段就拦下（用临时脚本验证过：命中即退出码 1，且不覆盖 `out/` 里已打的包）。
- `build.sh`：Python 回退的解释器探测从「`command -v python3 || command -v python`」改为
  逐个 `-V` 试跑。本机 PATH 上有个微软商店留下的 `python3` 空壳别名，只查存在性会挑中它，
  于是整模块拼装一路正常、到最后一步打包才失败。
- `module.prop`：`version=v1.0.4-omk-r9`、`versionCode=10409`。

### 说明

- 出货引擎仍是 OhMyKeymint `1.2.0-preview-a1f3241`（`libs/arm64-v8a/keymint`，sha256
  `f02edf28…`）。`1.3.5` 只存在于参考目录，是第三方分支，不是本仓库的引擎。
- 设备那份 keybox（13,579 B，sha256 `286c6680…39d3c`，与 r8 诊断日志记的摘要首尾一致）
  **已被吊销**：两条链的叶证书 `1698420960673666191`（ECDSA）与 `15510740886364958753`
  （RSA）都在册，`status=REVOKED / reason=KEY_COMPROMISE`，中间证书与根不在册 —— 公开镜像
  的 key 泄漏之后就是这个吊销形态。用 09-30 12:05 缓存的列表和当天最新的列表各查一遍结论
  相同（两份都是 1759 条），所以不是列表刚刚更新过。
- 镜像站 `http://evoker.qzz.io/key` 当前那份是 base64（22,572 B，解码后 16,927 B，
  `DeviceID="t.me/keyboxstrong @evokerr"`，ECDSA + RSA 各 3 张证书），**两道校验都通过**；
  它与设备上那份（13,579 B）以及 r8 日志里的 18,108 B 都不同 —— 镜像已经换过 key。
  `keybox_fetch.sh` 先解码再校验（第 156 行），校验落在解码后的文件上，所以 base64 这层不会
  让新闸门误拦。刷 r9 后点 [Action] 就会把它换上。
- 校验顺序仍有一处刻意的不对称：`keybox_fetch.sh` 把吊销检查放在变更检测之后（第 192 行），
  为的是每小时例行同步不必每次都去拉 179 KB 的列表；列表取不到时 fail-open，只有确认在册
  才拒装。

## v1.0.4-omk-r8 — 2026-09-30

修掉「一份畸形 keybox 被同步进 OMK 运行时目录，keymint 拒绝它并回退内置模板，Play
Integrity 三项全红」这条路径 —— 它比「keybox 被吊销」的两绿一红更糟，而且完全是模块
自己放进去的。

### 修复

- **畸形 keybox 不再被写进 OMK 运行时目录**：OhMyKeymint 解析 keybox 时若发现某个
  `<Key>` 条目不完整（典型是**缺 RSA 条目**），会**拒收整份文件**，而且**不保留原来
  那份可用的** —— 它改写成自己内置的模板（`DeviceID="sw"`，Google 无法验证的占位链），
  三项判定因此全红。设备日志里就是这三行：
  ```
  [WARN] keymint::keybox - invalid keybox.xml at /data/misc/keystore/omk/keybox.xml:
         missing RSA key entry in keybox.xml; rewriting bundled template
  [DEBUG] keymint::keybox - keybox reload completed without identity change (fallback=true)
  [WARN] keymint::keymaster::service - Skipping stale keybox-bound entry retirement
         while keybox fallback is active.
  ```
  复现路径：用户把一份 4220 字节的 keybox（应用导入，属主 `u0_a225:media_rw`）放进
  配置目录，而模块此前只按「文件里有没有 `Keybox` 这个字符串」放行，于是这份文件被
  一路同步进 OMK 的运行时目录，keymint 重启后拒收它、回退模板。
  - 新增 `module/keybox_check.sh`：按 keymint 实际挑剔的顺序做**结构化校验** ——
    `<AndroidAttestation>` 根、`<Keybox>`、`<NumberOfKeyboxes> >= 1`、**至少一个
    `<Key algorithm="rsa">`**、每个 `<Key>` 都要有带 PEM 的 `<PrivateKey>` 与非空的
    `<CertificateChain>`；不合格时逐条打印原因，退出码 0/1/2（可用 / 不可用 / 读不到）。
  - `omk-early.sh`：落盘前先校验。这是最要命的一处 —— 它跑在 keymint 启动之前，写进去
    什么 keymint 第一次就解析什么。现在配置目录的 keybox 不可用就**不种**，改用模块自带
    的那份；两份都不可用就不建这个文件，让 keymint 用它的模板、由 `omk-sync.sh` 稍后
    换成好的（模板只是两绿一红，被拒收一份文件才是三红）。
  - `omk-sync.sh`：新增 `kb_usable()`，不可用的 keybox 不复制到 OMK 运行时目录，保留
    上一份可用的。
  - `keybox_fetch.sh`：下载并解码后校验，不合格就**不落盘**，保住磁盘上那份。
  - `action.sh`：三处 `grep -q "Keybox"` 全部换成结构化校验。副作用是**自愈** —— 磁盘上
    那份不可用时不再被误判成「keybox ok」而跳过拉取，Action 会去拉镜像那份（同样经过
    校验）覆盖掉坏文件。
  - `webroot/index.html`：导入 keybox 时改用同一个校验器，并**在手机上直接显示第一条
    原因**（原来只报一句 "Not a valid keybox"，看不出哪里不对）。

### 变更

- `collect_logs.sh`：
  - Keybox 段的 `looks-like-keybox:` 换成 `usable-by-keymint: yes/NO`，为 NO 时逐条
    打印原因并给出修法；
  - OMK 段新增 `keybox fallback (keymint)`：命中 `invalid keybox` /
    `rewriting bundled template` / `fallback=true` / `missing RSA key entry` 就点名
    「keymint 已回退内置模板，三项必然全红」，并提示重跑 Action 重新拉取、仍红则清一次
    Google Play 服务的数据；
  - OMK 段新增运行时 keybox 与配置目录 keybox 的哈希比对，不一致时提示 keymint 读的
    不是用户以为的那份。
- `module.prop`：`version=v1.0.4-omk-r8`、`versionCode=10408`。
- 清掉两处没有任何调用点的死代码：`engine.sh` 的 `engine_spoof_keystore_keys()`，以及
  `service.sh` 里那个由 `teesim_gen_config` 改名而来、但没有任何随模块发布的引擎会定义
  的 `attest_gen_config` 空钩子。
- `build.sh`：本机既没有 `zip` 也没有 MSYS 可借，新增 Python 回退 `scripts/zipdir.py`，
  写出与 `zip -qr9` 相同的归档形态与 Unix 模式；`zip` 存在时仍优先用它。

### 说明

- 校验器只管**结构**：不做签名验证、不比对叶证书与私钥、不查 Google 吊销列表 —— 一份
  格式完好但已被吊销的 keybox 照样通过，代价是 STRONG（常规的两绿一红）。它拦的是更糟
  的那一类：keymint 直接拒收、三项全红。
- 本次排查的两份日志里只有一份命中这个缺陷；另一份（`store was dropped and rebuilt this
  boot`）是 r6 那个 pin 换来的最后一次丢库，处置同 r7：清一次 Google Play 服务的数据让
  GMS 重新申领证明密钥。
- 顺带核对过镜像分发的 keybox（13579 字节，sha256 `286c6680…`）：结构完整（ECDSA + RSA
  双条目，各 3 张证书），且~~其证书序列号**不在** Google 的吊销列表里~~ ——
  **这半句经 r9 复核作废**：两条链的叶证书 `1698420960673666191`（ECDSA）与
  `15510740886364958753`（RSA）都在册，`REVOKED / KEY_COMPROMISE`，这份 keybox 是**被吊销的**。
  结构完整那半句仍然成立，那份日志的三项全红也确实有上面这条回退 —— 也就是说同一台设备同时
  踩着「被 keymint 拒收」与「被 Google 吊销」两条，回退先修，吊销要靠换 key（见 r9）。
- `module.prop` **有意不带 `updateJson=`**，这是决定，不是漏抄：上游那行指向
  `evoker0/AlwaysStrong` 的 `update.json`，其 `zipUrl` 是上游 TEE-Simulator 整包。本仓库
  `versionCode=10408` 高于上游的 104，Magisk 按数值比较不会提示；但管理器一旦按字符串
  比较、或上游改用 PIF 那种六位 versionCode，就会弹出「有更新」并把人刷回非 OMK 版 ——
  而上游的卸载路径会删 OMK 密钥库（r7 修掉的坑）。要 OTA 就另发一份本仓库自己的
  `update.json` 并指向这里，而不是恢复这一行。

## v1.0.4-omk-r7 — 2026-09-29

修掉「卸载重装本模块会永久毁掉 OMK 密钥库」这个真正的坑，并给 `config.toml` 的
`[crypto]` 种子加上抢救与留痕 —— 前者才是「Play Integrity 三项全红且怎么刷都不恢复」
的直接原因。

### 修复

- **卸载时不再删除 OMK 密钥库**：`uninstall.sh` 原来会 `rm -rf /data/adb/omk
  /data/misc/keystore/omk`。后者的 `data/` 就是 OMK 的密钥库 —— OMK 造过的每一把密钥
  都在里面，**包括 GMS 用来做 Play Integrity 证明的那把**，而它由同目录 `config.toml`
  的 `[crypto]` 种子封装。卸载模块并不会把这些密钥搬回系统后端，所以删库 = 密钥永久
  丢失，只能等 GMS 重新申领（实践中就是清 Google Play 服务的数据）。
  本模块的常规升级方式恰恰是「卸载 → 重装」，于是每次刷版本都会把库删掉一次，
  表现为「刷到某个版本就三项全红、退回旧版本也还是红」，很容易被误判成那个版本引入的
  回归。现在两个根目录一律保留，只清我们自己的临时状态（pidfile / restart 标志）。
  需要干净重来的用户可以手动删 `/data/misc/keystore/omk` 与 `/data/adb/omk`。
- **`config.toml` 丢失后自动抢救**：上游文档明确写着，keymint 启动时若该文件不存在，
  它会重新生成一份**带全新种子**的，而新种子**无法解开**旧种子封的库 —— 整库作废，
  keymint 报 `failed to decrypt keyblob … VerificationFailed`、
  `failed to initialize boot-level key cache` 后退出，omk-daemon 随即将库丢弃重建。
  `omk-sync.sh` 现在把最后一份**四个 `[crypto]` 字段齐全**的 `config.toml` 备份到
  `/data/adb/omk/config.toml.keep`（缺字段的半成品不备份，避免污染恢复），
  `omk-early.sh` 在 keymint 启动前发现运行时文件缺失就从备份还原。种子因此能扛住
  除「显式重置」以外的一切。

### 变更

- `omk-early.sh`：每次开机把 `[crypto]` 种子的哈希指纹（只记哈希，永不落明文）追加到
  `/data/adb/omk/crypto-history.log`（保留最近 40 条），这样一份日志就能看出种子是否
  在跨开机变化 —— 会变，就是故障本身。
- `collect_logs.sh`：OMK 段新增
  - `config.toml.keep` 的存在与指纹，以及与运行中文件不一致时的 WARN；
  - 密钥库与 `config.toml` 「一个在一个不在」时的 WARN（这是下一次启动必然丢库的状态）；
  - 最近两次开机的 `[crypto]` 指纹不同时的 WARN，直接点名「库会被丢」。
- `module.prop`：`version=v1.0.4-omk-r7`、`versionCode=10407`。

### 说明

r6 的 pin 已经让 KeyMint 实例选择稳定下来（`level-zero KM strategy` 固定为
`TRUSTED_ENVIRONMENT:MAX_USES_PER_BOOT`），但**钉住的当下会换来最后一次丢库**：旧库
是被另一个实例/策略封的，解不开，只能重建。r7 不改变这个 pin，所以升级 r7 不会再触发
新的丢库。要回到三项全绿，重装 r7 后重启，然后清一次 Google Play 服务的数据让 GMS
重新申领证明密钥；再跑一次 Action → 日志，确认
`store was dropped and rebuilt this boot` 不再出现、`[crypto] fingerprint` 连续两次开机
一致。

## v1.0.4-omk-r6 — 2026-09-29

修复「OhMyKeymint 的密钥库每次开机被重建，导致 Play Integrity 三项全红」的根因 ——
与补丁日期无关，r2fix 上同样复现。

### 修复

- **OMK 私密存储被反复重建**：日志里每次开机都有
  `store was dropped and rebuilt this boot`，触发行是
  `fatal startup error: failed to initialize boot-level key cache … Error::Km(ErrorCode(-33))`
  （`-33` = `KM_ERROR_INVALID_KEY_BLOB`）。OMK 用它选中的那个 KeyMint 实例来封装
  boot-level key，而「选哪个实例」在每次 keymint 启动时都要靠探测 TEE / StrongBox
  版本来推断（`boot_key.rs`：先看 TEE，TEE < 4.1 时再去问 StrongBox 在不在）。这台设备
  的 TEE 报的 KeyMint < 4.1、同时又存在 StrongBox 实例，于是选择取决于「此刻 StrongBox
  注册了没有」；而本模块是在 service 阶段（`boot_completed` 之前）就拉起 keymint 的，
  这个答案会在多次启动之间翻转。一旦翻转，boot-level key 的密文是另一个实例封的，
  解不开 —— 上面那条 fatal 就是这么来的，omk-daemon 的自愈随之把整个存储删掉重建，
  **包括 GMS 的证明密钥在内所有应用密钥一起丢失**，Play Integrity 三项因此全红。
  - `post-fs-data.sh`：在 keymint 启动前把
    `ro.keystore.boot_level_key.strategy` 钉成 `TRUSTED_ENVIRONMENT:MAX_USES_PER_BOOT`
    （仅在 ROM 未设置时写）。上游在 `boot_key.rs` 里明确要求该值一经确定就不得变化，
    钉住后选择不再翻转，存储不会再被误删。选 TEE 是因为它一定存在（StrongBox 早期
    可能尚未注册），选 `MAX_USES_PER_BOOT` 是因为它不要求 KeyMint 4.1。
- **误删的存储现在可恢复**：同一段 fatal 也可能来自真实的 seed 变化，但若起因是上面
  的实例翻转，那些密文其实是完好的（只是被另一个实例封着）。`omk-daemon` 删除前会把
  存储复制一份到 `/data/adb/omk/store-dropped`（单槽，覆盖式，不会无限增长）。

### 变更

- `collect_logs.sh`：OMK runtime 段新增 `level-zero KM strategy:` 一行，打印钉住的值；
  存储被重建时额外打印 `dropped store kept at …`。
- `module.prop`：`version=v1.0.4-omk-r6`、`versionCode=10406`。

### 说明

钉住之后最多还会再重建一次存储（当前这份密文是旧实例封的），之后稳定；重建后 GMS 的
证明密钥会重新生成，若三项仍红可稍等片刻，仍不行再清一次 Google Play 服务的数据。

怎么确认生效：重装 r6 后重启，跑一次 Action → 日志（或 `action.sh logs`），OMK runtime
段里 `level-zero KM strategy:` 应显示 `TRUSTED_ENVIRONMENT:MAX_USES_PER_BOOT`；此后
`store was dropped and rebuilt this boot` 不应再出现，说明存储不再被误删。

## v1.0.4-omk-r5 — 2026-09-29

修正 r4 实验性开关的默认状态与说明，并修掉开关开启时 PIF 补丁日期写不进去的缺陷。

### 修复

- **开关开启时 Play Integrity 三项全红**：`sync_patch.sh` 写 pif 的 `*.security_patch`
  用的是裸 `toybox sed -i`，部分 ROM 上这条编辑静默不生效。默认模式下 `EFF` 恰好等于
  指纹自带日期，`migrate.sh` 早已写过同一个值，所以文件看起来是对的；一旦「统一日期」
  把 `EFF` 抬到 ROM 的真实补丁，pif 仍停在指纹日期，而 `security_patch.txt` 与系统属性
  已经跟着走了 —— 日志里就是这种三处不一致（`security_patch.txt` 2026-09-01、
  `pif *.security_patch` 2026-08-05、属性 2026-09-01），三项判定因此全红。
  - 改为优先使用 busybox `sed`，写完立刻回读校验，读回不等于目标值就整文件重建
    （`grep -v` 过滤旧行 + 追加新行 + `cat` 回写同一 inode，保留权限与 SELinux 上下文），
    不再依赖某个 sed 实现是否支持就地编辑。
- **开关默认状态**：r4 里该开关是「开（默认）」，与用户预期相反。现在默认关闭 ——
  全新安装与升级都等同 r2fix 的行为：三处一律用指纹自带日期。标志文件也从
  `spoof_patch_props`（r4 的「严格」语义）改名 `unified_patch_date`（现在的「统一」语义），
  并在 `sync_patch.sh` 里清掉可能残留的旧标志，避免升级继承一个已失效的状态。

### 变更

- `webroot/index.html`：「统一日期策略（测试）」的说明改为明确指向
  **Tampered Attestation Key 26** 这一项，并标注关闭为默认值；en / tr / zh 三份文案同步。
- `collect_logs.sh`：`date mode:` 一行改为按 `unified_patch_date` 判断，直接打印
  「strict fingerprint, own date (default)」或「unified, newest of fingerprint/ROM (experimental toggle ON)」。
- `module.prop`：`version=v1.0.4-omk-r5`、`versionCode=10405`。

## v1.0.4-omk-r4 — 2026-09-29

把 r3 的日期策略做成 WebUI 上的实验性开关，供排查「Tampered Attestation Key」用。

### 新增

- `webroot/index.html`：Advanced 页新增「统一日期策略（测试）」一行（琥珀色警示样式 +
  `测试` 角标），位于「Spoof security patch」下方：
  - **开（默认）** = r3 逻辑：三处日期取「指纹补丁」与「ROM 真实补丁」中较新的一个；
  - **关** = 严格使用指纹自带日期，忽略 ROM 更新的真实补丁 —— 即 r3 之前的行为。
  - 切换后立即调用 `sync_patch.sh boot` 生效，无需重启。
  - 行内注明这是实验性排查项，并明确「Tampered Attestation Key 通常与 keybox 有关，
    本项未必有效」。
  - 文案进 en / tr / zh，其余语言回退英文。
- 底层复用 `sync_patch.sh` 既有的 `spoof_patch_props` 强制分支（`FORCE=1`），
  WebUI 开关关闭时创建该文件，打开时删除。

### 变更

- `collect_logs.sh`：日期一致性段新增 `date mode:` 一行，打印当前用的是统一日期还是
  严格指纹日期。
- `sync_patch.sh`：为 `FORCE` 分支补充说明注释（它是 WebUI 该开关的落地）。
- `module.prop`：`version=v1.0.4-omk-r4`、`versionCode=10404`。

### 说明

`Tampered Attestation Key` 指证明密钥被判定为篡改，绝大多数情况是 keybox 被 Google
判定为共享滥用或证书链不合法，与安全补丁日期无关。本开关是给用户做 A/B 排查用的
逃生口，不是该报错的修复项。

## v1.0.4-omk-r3 — 2026-09-29

修复安全补丁日期「被自动改写」与「三处日期互相不一致」两个问题。

### 修复

- **三处日期统一为一个值**：安全补丁日期此前分散在三处 —— 系统属性
  `ro.build.version.security_patch`、`/data/adb/tricky_store/security_patch.txt`
  （引擎写进硬件证明的 osPatchLevel）、以及 pif 的 `*.security_patch`（PIF 的
  zygisk 报给 GMS 的日期）。OhMyKeymint 的 `config.toml` 补丁字段保持 `auto`，
  所以引擎证明最终也跟随系统属性。三者必须一致，否则证明校验会报
  「OS patch 与 osPatchLevel 不符」。
  - `sync_patch.sh`：改为先算出一个统一日期 `EFF`，三处全部由它写入。
    - 默认：取指纹的 `SECURITY_PATCH`，但不早于 ROM 自身补丁 —— 即
      「只前进不后退」，OTA 跑在指纹前面时保留更新的真实日期。
    - 关闭补丁伪装（`no_spoof_patch_props`）：三处一律使用 ROM 真实日期，
      不再出现「属性回到真实、另外两处还在伪装」的错位。
  - `post-fs-data.sh`：在任何地方改写属性之前，先把 ROM 真实补丁记录到
    `/data/adb/tricky_store/.rom_security_patch`（每次开机刷新，自动跟随 OTA），
    供上面的「下限」与「真实日期」使用。
- **每小时刷新只改一半**：`service.sh` 的小时任务此前以非 boot 模式调用
  `sync_patch.sh`，只更新 `security_patch.txt`，系统属性要等下次重启才跟上，
  期间就会出现属性与证明日期不一致。现在小时任务同样以 boot 模式运行，
  属性随指纹一起重钉；`sync_patch.sh` 幂等，未变动的小时是空操作。

### 变更

- `webroot/index.html`：`spp`（Spoof security patch）开关说明改为「三处日期统一
  为一个值，关闭时三处都使用 ROM 真实日期」；切换时立即生效（开启与关闭都会
  立刻调用 `sync_patch.sh boot`），不再需要重启才生效。
- `collect_logs.sh`：新增「Security patch consistency」段，打印开关状态、
  ROM 真实日期、`security_patch.txt`、pif `*.security_patch` 与系统属性，
  不一致时直接给出 WARN。
- `uninstall.sh`：清理 `.rom_security_patch` 缓存。
- `module.prop`：`version=v1.0.4-omk-r3`、`versionCode=10403`。

## v1.0.4-omk-r2fix — 2026-09-28

在保持一加等机型三项全红修复的前提下，让三个冲突开关恢复可开启，改为在 WebUI 里
说明开启后果。

### 变更

- **`spoofProvider` / `spoofSignature` / `spoofVendingSdk` 不再被强制锁定**：
  r2 里这三个键被引擎忽略、WebUI 开关置灰，用户无法开启。本版改为
  「升级时一次性清理 + 之后尊重用户选择」：
  - `engine.sh`：移除 `engine_locked_keys()`；新增 `engine_migrate_spoof_conf()`，
    在 `engine_enforce_spoof()` 首次运行时，把从旧的非 OMK 安装继承下来的这三个键
    从 `spoof.conf` 中删除一次（标记 `/data/adb/tricky_store/.spoof_keys_purged`，
    该目录跨模块更新保留），之后 `spoof.conf` 里的取值一律生效。
    这样升级不会再继承一份让三项全红的配置，而用户明确开启时仍然可用。
  - `webroot/index.html`：三个开关恢复为可点；行内加琥珀色警示说明，注明「开启后
    PlayIntegrityFork 会伪造证明引擎正在应答的 keystore 调用，两者冲突会导致
    Play Integrity 三项判定全部变红」，开启时再弹一条警示 toast。
    `spoofwarn` / `spoofwarn_toast` / `spoofwarn_tag` 已加入 en / tr / zh 文案，
    其余语言回退英文。
- `collect_logs.sh`：把「键已被锁定、这行无效」的提示改为「该键为开启状态，会与
  证明引擎冲突导致三项全红」的告警，并报告一次性清理是否已执行。
- `module.prop`：`version=v1.0.4-omk-r2fix`、`versionCode=10402`。

## v1.0.4-omk-r2 — 2026-09-28

修复一加等机型上 Play Integrity 三项全红的问题。

### 修复

- **PIF 与 OMK 争抢 keystore 导致三项全红**：`spoofProvider` / `spoofSignature` /
  `spoofVendingSdk` 三个标志会让 PlayIntegrityFork 的 zygisk 去拦截 OhMyKeymint
  正在应答的同一批 keystore 调用，两边互相打架，三项判定全部变红。
  从旧的非 OMK 安装带过来的 `spoof.conf` 是最常见的触发来源。
  - `engine.sh`：新增 `engine_locked_keys()`，`engine_spoof_val()` 对这三个键
    一律取默认值（均为 0），忽略 `spoof.conf` 里的任何覆盖；其余标志仍可由
    WebUI 覆盖。更新后首次开机 `action.sh` 会自动把三键强制写回 0。
  - `webroot/index.html`：Advanced 页把这三个开关渲染为「locked」并置灰禁用，
    防止再次写入冲突值。

### 变更

- `collect_logs.sh`：新增 `spoof.conf` 内容与「实际生效的 spoof 标志」诊断，
  并对被锁定但仍留在 `spoof.conf` 里的键给出提示，避免误判。
- `module.prop`：`version=v1.0.4-omk-r2`、`versionCode=10401`。

## v1.0.4-omk — 2026-09-28

首个公开版本。基于 [AlwaysStrong v1.0.4](https://github.com/evoker0/AlwaysStrong) 骨架，
将证明引擎替换为 [OhMyKeymint 1.2.0-preview-a1f3241](https://github.com/qwq233/OhMyKeymint/releases/tag/1.2.0-preview-a1f3241)。

### 新增

- `attest/omk.sh`：OhMyKeymint 适配层，构建时覆盖为模块内的 `attest.sh`，
  负责引擎安装、启动、状态检测、配置同步与注入兜底。
- `omk-daemon`：keymint 守护进程。APEX 优先的库搜索顺序；启动崩溃自愈。
- `omk-injector`：注入器包装，等待 RPC 就绪后注入 keystore2。
- `omk-early.sh`：`post-fs-data` 阶段清理跨开机残留的 `keymint.log.store-reset` 标记。
- `omk-sync.sh`：把 OMK 配置面镜像桥接到 `/data/adb/tricky_store`。
- `collect_logs.sh`：新增私有存储列表、`crash_count`、store-reset 标记与触发原因诊断。

### 修复

- **Android 17 / SDK 37 链接失败**：keymint 报
  `cannot locate symbol "_ZNSt3__113__hash_memoryEPKvm"`。修正 `LD_LIBRARY_PATH`，
  将 `/apex/com.android.runtime/lib64` 置于 `/system/lib64`、`/vendor/lib64` 之前。
- **私有存储无法解密导致无限重启**：新增双门控自愈 —— 60 秒内非请求快速退出 ≥ 2 次，
  且 `keymint.log` 出现 `failed to decrypt keyblob` /
  `failed to initialize boot-level key cache` 等签名时，重建
  `/data/misc/keystore/omk/data`，并保留重建前日志为 `logs/keymint.log.store-reset`。
- **错过 RPC 窗口导致注入失败**：新增 `attest_ensure_injection()`，依据 `rpc.sock`
  时间戳与 `injector.log` 事件判定，15 分钟冷却后自动重注入。
- **`collect_logs.sh` 中 `ATTEST=?` 恒显示**：改为从 `attest.sh` 解析 `ATTEST` 变量。
- **store-reset 标记跨开机残留** 造成的诊断假阳性。

### 变更

- `module.prop`：`version=v1.0.4-omk`、`versionCode=10400`，
  描述改为 `OhMyKeymint + PlayIntegrityFork`，作者列表补充 James Clef、qwq233。
- 移除 `updateJson`（不提供在线更新）。
- `conflict_scan.sh`：检测到独立 OhMyKeymint 模块时禁用本模块。
- SELinux 规则取「AlwaysStrong 原规则 ∪ 上游 OMK 规则」，未引入 TCP 调试面。

### 保留

- PlayIntegrityFork v18 及其适配层 `engine.sh`。
- `asfetch` / `aswatcher` 原生指纹抓取与自动刷新。
- WebUI 与 Action 按钮。
- keybox 抢救逻辑：覆盖引擎前备份到 `/data/adb/omk/guard.keybox.xml`，
  恢复后写回；仅在 keybox 与内置版本不同时写回。

### 已知限制

- 仅支持 **arm64-v8a**（OhMyKeymint 上游只提供 arm64-v8a 载荷）。
- 不能与独立 OhMyKeymint 模块同时安装。
- 从其他 OMK 引擎切换过来的**首次开机**，旧密钥 blob 可能无法解密，
  自愈逻辑会重建私有存储；此时旧应用密钥失效属预期行为。

---

## 捐赠

创作不易，感谢支持。

![捐赠二维码](./module/webroot/donate.png)
