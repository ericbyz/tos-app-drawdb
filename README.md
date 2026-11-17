# tos-app-drawdb

将 [DrawDB](https://github.com/drawdb-io/drawdb)(数据库 ER 图设计器,AGPL-3.0)打包为 [铁威马 TOS](https://www.terra-master.com) 应用中心 **deb 类应用**(x86_64 + aarch64 双架构)。

**这是什么**:TOS deb 封装仓。上游无整站发布产物,`scripts/build_web.sh` 在锁定 commit 上一次性构建 dist(vite `--base=/drawdb/`),并把运行时按需加载的 monaco 编辑器、pdfobject 与图标字体**全部捆绑本地化**,锁定 SHA256(`webui/SHA256SUMS`)后随仓提交 —— 任何机器无需 node 工具链即可打 deb。

| 项目 | 值 |
|---|---|
| 应用 ID | `drawdb` |
| 应用形态 | deb 类 · **纯静态页**(`type=iframe`, `exec=false`),无服务进程、不占端口 |
| 悬浮路由 | `http://<NAS>/drawdb/`(TOS nginx alias + **BrowserRouter history fallback**) |
| 上游版本 | v1.9.0,commit `a249c7fb730c2de9b5c2ce6e863f2ea7344ac372`(见 [UPSTREAM](UPSTREAM)) |
| 构建 pin | node ≥20.12(便携 node22,不装系统)+ npm ci;dist 141 文件 / SHA256SUMS 锁定 |
| 上游许可证 | AGPL-3.0(全文见 [LICENSE](LICENSE),义务见 [NOTICE](NOTICE);封装层 MIT) |
| 数据目录 | 无(纯前端;图表存浏览器 localStorage / 导出文件) |

## 本地化要点(上游运行时 CDN 依赖清零)

| 运行时依赖 | 上游来源 | 本仓处理 |
|---|---|---|
| monaco 编辑器(SQL/DBML 代码视图) | `cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs` | npm tarball 捆绑至 `webui/monaco/min/vs`,JS 内 URL 补丁指向 `/drawdb/monaco/min/vs` |
| pdfobject(文档预览) | `cdnjs.cloudflare.com/.../pdfobject.min.js` | 捆绑至 `webui/assets/vendor/`,URL 补丁 |
| bootstrap-icons / font-awesome 字体 | jsdelivr / cdnjs | CSS+woff/woff2 捆绑至 `webui/assets/fonts/`,CSS 内相对路径重写 |
| iconify API | 无(离线图标) | — |

构建后强制校验:dist 无任何 CDN 引用、无 Windows 盘符路径泄漏(MSYS 防回归)、
monaco/pdfobject/fonts 就位,再生成 SHA256SUMS。

## 目录结构

```
tos-app-drawdb/
├── config.ini                # TOS 平台元数据(type=iframe + exec=false)
├── drawdb.lang               # 26 种语言(生成:scripts/make_lang.py)
├── UPSTREAM                  # 版本锁定(上游 repo/tag/commit + 工具链 + vendor 清单)
├── webui/                    # ⭐ 构建产物(提交进仓,141 文件)+ SHA256SUMS 清单
├── nginx/drawdb.conf         # TOS nginx 静态 alias + SPA fallback
├── DEBIAN/                   # control + postinst/prerm/postrm(无服务)
├── images/icons/drawdb.svg   # 原创图标(ER 关系卡)
├── scripts/
│   ├── build_web.sh          # ⭐ 上游构建 + vendor 本地化 + SHA256 锁定(可复现)
│   ├── build_deb.py          # 纯 Python dpkg-deb 兼容打包器(确定性构建)
│   ├── unpack_check.py       # .deb 解包验证(control/webui/SHA256SUMS 全量核对 + CDN 扫描)
│   ├── validate.py           # TOS 审核规则校验(iframe+静态 alias 分支)
│   ├── make_lang.py          # 生成 drawdb.lang
│   └── bump_upstream.sh      # 升级版本
├── build.sh                  # 一键打包 ./build.sh [x86_64|aarch64](先核验 SHA256SUMS)
├── LICENSE                   # 上游 AGPL-3.0 全文
└── NOTICE                    # 归属与构建变换说明
```

## 重新构建 dist(升级或复现)

依赖:git、gh CLI、node ≥20.12(便携 node22 自动拉取)、bash、python3。

```bash
./scripts/build_web.sh                 # tarball(锁定 commit)→ npm ci → vite build → vendor 捆绑 → webui/
./scripts/build_web.sh --no-install    # 跳过依赖安装(已装时)
./build.sh                             # 打双架构 deb(先核验 webui 对 SHA256SUMS)
./scripts/validate.py                  # 元数据 + 内网化校验
```

产物:`build/output/drawdb_<platform>.deb` + `.sha256`(约 12MB,xz 压缩 33MB dist)。
`unpack_check.py` 解包后**逐文件核对 SHA256SUMS 并扫描 CDN 引用**。

## 上架 Checklist(内部奖励计划 · deb 档 60 元)

1. ☐ 推送本仓 GitHub(ericbyz/tos-app-drawdb)+ 打 tag `v1.9.0`;
2. ☐ 提交前**刷新查重**(`drawdb` / `Draw DB`,2026-11-16 核验空白);
3. ☐ x86_64 与 ARM **分别创建应用**(独立 App ID、同一开发者账号);
4. ☐ 提交 Release 直链 + SHA256 + 上游源码仓 + commit pin 说明;
5. ☐ VM 实测:raw dpkg 安装 + 接线,悬浮窗打开、拖拽建表、导出 SQL 截图;
6. ☐ 《参与报名表》勾选 deb 档,附仓库链接;
7. ☐ 30 天内维护 Issues 响应。

## 合规声明

- 上游源码**零改动**;仅对构建产物做打包级变换(vendor 本地化),详见 [NOTICE](NOTICE);
- AGPL-3.0:分发的是未修改上游源码在 pinned commit 的构建产物,对应源码即上游
  commit(构建配方 build_web.sh 随仓公开),满足 AGPL 源码提供义务;
- 安装包无二进制、无服务、无遥测;不收集任何用户数据,图表仅存于用户浏览器本地。
