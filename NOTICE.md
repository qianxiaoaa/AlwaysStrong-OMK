# NOTICE — 第三方组件、修改声明与免责声明

本仓库（`AlwaysStrong-OMK`）是第三方非官方二改项目。以下内容依据
GPL-3.0 §5 / AGPL-3.0 §5 的「标明修改」义务与 AGPL-3.0 §13 的组合作品要求编写。

---

## 1. 组件清单

| 组件 | 版本 | 著作权人 | 许可证 | 上游 |
|---|---|---|---|---|
| OhMyKeymint | `1.3.5-196-10113e7`（ITxiao6666 分支） | qwq233、ITxiao6666 及贡献者 | AGPL-3.0-or-later + 附加条款 | https://github.com/ITxiao6666/OhMyKeymint |
| AlwaysStrong | `v1.0.4` | Evokerr (evoker0) 及贡献者 | GPL-3.0 | https://github.com/evoker0/AlwaysStrong |
| PlayIntegrityFork | `v18` | osm0sis 及贡献者 | GPL-3.0 | https://github.com/osm0sis/PlayIntegrityFork |
| yypm | 未标注版本 | yangyang8002 及贡献者 | 未声明（上游仓库无 LICENSE 文件） | https://github.com/yangyang8002/yypm |

许可证全文：

- AGPL-3.0（本合并作品的许可证）：[`LICENSE`](LICENSE)
- GPL-3.0（AlwaysStrong / PlayIntegrityFork）：[`LICENSE-GPL-3.0.txt`](LICENSE-GPL-3.0.txt)
- OhMyKeymint 附加条款：[`LICENSE-OhMyKeymint.txt`](LICENSE-OhMyKeymint.txt)

---

## 2. 组合作品与许可证结论

- AlwaysStrong 与 PlayIntegrityFork 为 **GPL-3.0**；OhMyKeymint 为
  **AGPL-3.0-or-later** 并附有额外条款。
- GPL-3.0 与 AGPL-3.0 相互兼容；AGPL-3.0 §13 明确允许将 GPL-3.0 作品与
  AGPL-3.0 作品组合，组合后的整体必须按 AGPL-3.0 分发。
- 因此，**本仓库整体以 AGPL-3.0-or-later 发布**，并同时受 OhMyKeymint
  附加条款约束（商业使用禁止、不得暗示从属关系、名称使用限制等）。
- 若附加条款与 AGPL 冲突，就 OhMyKeymint 作者拥有完全著作权的部分而言，
  以附加条款为准。

### 使用者需要遵守的额外限制

1. **禁止商业用途。** 不得将本模块（或其任意部分、或以本模块为依赖的软件）
   用于任何以盈利为目的的用途，包括但不限于与其他资源、物品或服务捆绑销售。
2. **不得暗示从属关系。** 不得以任何方式暗示本二改版本与 OhMyKeymint 或
   AlwaysStrong 的官方作者存在从属、赞助或背书关系。
3. **名称使用限制。** 未经 OhMyKeymint 作者书面许可，不得超出合理使用范围
   使用其名称。本仓库名中的 "OMK" 仅作描述性说明用途。
4. **网络分发条款（AGPL §13）。** 若你修改本模块并通过网络向他人提供服务，
   必须向使用者提供对应的完整源码。

---

## 3. 修改声明

本仓库相对上游 AlwaysStrong v1.0.4 的修改（修改日期：2026-09-28）：

- 将证明引擎由 **TEESimulator-RS v6.0.1-307** 替换为
  **OhMyKeymint 1.3.5-196-10113e7**（ITxiao6666 分支，官方 1.2.0-preview 的衍生版）。
- 新增适配层 `attest/omk.sh`（构建时覆盖为模块内的 `attest.sh`），
  替代上游的 `attest/tee.sh`。
- 新增模块脚本：`omk-daemon`、`omk-injector`、`omk-early.sh`、`omk-sync.sh`。
- 修改 `service.sh`、`customize.sh`、`conflict_scan.sh`、`collect_logs.sh`、
  `module.prop` 等，接入 OhMyKeymint 的安装、启动、状态检测、同步与注入兜底。
- `omk-daemon`：调整 `LD_LIBRARY_PATH` 顺序以修复 Android 17 / SDK 37 上的
  libc++ 符号缺失；新增私有存储解密失败时的双门控自愈逻辑。
- `attest.sh`：新增 `attest_ensure_injection()` 注入看门狗。
- `collect_logs.sh`：修复 `ATTEST` 变量解析，补充私有存储与重建诊断。
- `omk-early.sh`：新增跨开机 `keymint.log.store-reset` 标记清理。
- 未引入上游 OhMyKeymint 的 TCP 调试面；SELinux 规则为「AlwaysStrong 原规则
  ∪ 上游 OMK 规则」。

### r11 追加修改（修改日期：2026-10-08）

- 引擎升级到 **OhMyKeymint 1.3.5-196-10113e7**（ITxiao6666 分支），仅取 keystore 引擎部分
  （`libs/arm64-v8a/{keymint,inject,soterta-svc}`、`injector.toml`、`soterta.sh`），
  不使用 OMK 自带的 zygisk / `webroot/` / `daemon/`。
- 新增可选的 Qualcomm Soter 中继看护 `soterta.sh`（默认关闭）。
- keybox 默认来源改为 `ZeyolZZZ/TEESimulator-RS-fix`；PIF 指纹档案来源改为
  `Elcapitanoe/PIF-Config-Generator`；模块健康状态改为本地推导，移除对第三方状态镜像的依赖。

### r2 追加修改（修改日期：2026-10-08）

- keybox 采集移植 **yypm**（`php-server/lib/sources.php`、`config.php` 的多源配置、
  `lib/revocation.php` 的镜像顺序），改写为设备端 `module/keybox_sources.sh`：
  源列表、`base64` / `multi_base64_hex_rot13` / `hex_base64` 解码、GitHub 目录轮换取样、
  优先级 + 吊销择优逻辑均源自 yypm，按 POSIX sh 与 Magisk/KSU 环境重写。
- 吊销名单增加 `purainity` / `KimmyXYC` 镜像，保留 Google 官方兜底；`status_fetch.sh`
  同步。修复 `keybox_revoke_check.sh`：官方名单以序列号**十进制**为键，旧的十六进制匹配
  在真实名单上永远判不出吊销。
- 说明：yypm 上游仓库**未声明许可证**。本仓库对其逻辑的移植仅作功能复用并在此标注来源，
  著作权归原仓库作者；若原作者有异议，可移除相应实现。

### r4 追加修改（修改日期：2026-10-08）

- 新增签名式自更新分发，设计参考 **yypm**（其 PHP 服务端 `update.php` +
  `lib/sign.php` 的 Ed25519 签名清单、`verify_tool.go` 的端侧验签、`.github/workflows/mirror.yml`
  的镜像发布思路），改为**纯 GitHub Actions** 实现（本仓库无自建服务端）：
  - `native/verifier/src/verify_tool.go`：端侧 Ed25519 验签工具（独立实现，非复制）。
  - `scripts/build-verifier.sh`：交叉编译 4 个 ABI。
  - `scripts/gen-manifest.py`：生成签名清单 `manifest.json`。
  - `scripts/publish-manifest.sh` + `.github/workflows/manifest.yml`：发布清单到 release
    资产与 `mirror-data` 分支（`mirror/manifest.json`）。
  - `module/self_update.sh`：设备端拉取 / 校验 / 安装。
- 信任根：Ed25519 公钥随包分发（`module/pubkey.b64` + `pubkey.fp`），私钥仅存于仓库
  Actions Secret `ALWAYSSTRONG_SIGNING_KEY`，不进入仓库。
- 说明：同上，yypm 无许可证声明；此处为独立实现 + 思路借鉴，并标注来源。

上游文件的完整源码见各自仓库；本仓库中未修改的上游脚本保留其原始版权头。

---

## 4. 免责声明

- 本模块按「现状」提供，不附带任何明示或暗示的担保。
- 本模块会修改设备上的密钥证明行为，可能导致部分应用（尤其是银行、支付、
  风控类应用）出现异常，甚至影响设备保修状态。**请自行评估风险。**
- 请勿将本模块用于绕过你无权访问的服务，或任何违反当地法律法规的用途。
- 因使用本模块产生的一切后果，由使用者自行承担；本仓库作者不承担任何责任。

---

## 5. 无隶属关系声明

本项目为独立的第三方修改版本。**它不是** OhMyKeymint 或 AlwaysStrong 的官方
发行版，**未获得**其作者的赞助、授权或背书。所有上游项目的名称、标识与版权
归各自作者所有。
