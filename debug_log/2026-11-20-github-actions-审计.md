# GitHub Actions 审计与 CI 链路加固

## 2026-11-20 20:29

- **文件**：`.github/workflows/deploy.yml`、`_config.yml`
- **改动**：workflow 3 处（2 行改 + 4 行加）；`_config.yml` exclude 加 1 行

### 触发问题

用户反馈"Action 之前有 bug"，要求查看执行记录并修复，然后 push。

### 审计结果（GitHub REST API，无 token 只读公开仓库）

```bash
curl -s "https://api.github.com/repos/sdwyc/sdwyc.github.io/actions/runs?per_page=30"
```

| 项 | 结果 |
|---|---|
| run 总数 | **8**，全部 `schedule` 事件、全部 `success` |
| `event=push` | **0 条** |
| `status=failure` | **0 条** |
| 最早/最晚 run | 2025-12-10 / 2026-01-28，均为 CodeQL |

关键判断：

1. **没有失败记录**，用户看到的"红叉"其 run 记录已不在 API 返回里（日志/run 保留期已过）。
2. gh-pages 最新提交 `78753ed` 的 message 是
   `Deploying to gh-pages from @ sdwyc/sdwyc.github.io@8cb1731a9`，
   与 main 最新提交 `8cb1731` **对应一致** → 最后一次部署是成功的（2025-11-24）。
3. CodeQL 工作流状态为 `disabled_inactivity`（2026-01-28 之后被 GitHub 自动停用），
   所以定时扫描已经不跑了；此状态在服务端，**改文件无法恢复**，需在 Actions 页面点 "Enable"。
4. `broken-links.yml` / `deploy-image.yml` / `docker-slim.yml` 都带
   `if: github.repository_owner == 'alshedivat'`（上游 al-folio 的门禁），
   在本仓库**永远不会执行**，属设计如此，不是故障。

### 原因分析（找到的两处真实隐患）

1. **purgecss 未锁版本 + 依赖 runner 默认 Node**

   ```yaml
   npm install -g purgecss      # 拉到 9.1.0
   ```

   实测 npm registry：`purgecss@9.1.0` 的 `engines.node = ">=22.12.0"`，
   而 ubuntu-latest runner 默认 node 为 20.x。npm 对 engines 只告警不阻断，
   结果是装上了但在 20.x 上运行不可靠 —— 典型的"某天突然变红"型故障。
   同时 `purgecss.config.js` 用的是 v6 时代的 `skippedContentGlobs` 选项。

2. **`fjogeleit/yaml-update-action@main`**

   直接跟踪分支而非 release tag，上游任何 breaking change 都会立刻打进部署。

### 改动做法

```diff
-        uses: fjogeleit/yaml-update-action@main
+        uses: fjogeleit/yaml-update-action@v0.17.0
...
+      - name: Setup Node.js ⚙️
+        uses: actions/setup-node@v4
+        with:
+          node-version: "20"
       - name: Purge unused CSS 🧹
         run: |
-          npm install -g purgecss
+          npm install -g purgecss@6.0.0
           purgecss -c purgecss.config.js
```

`_config.yml`：

```diff
   - assets/jupyter/
+  - debug_log/ # internal change logs, not published
```

选 `purgecss@6.0.0` 的依据：实测其 bin 同时支持 `-c, --config <path>` 和
`skippedContentGlobs`，且 `engines` 为空（不限制 Node），与现有配置和 Node 20 完全匹配。

### 验证方式

```bash
# 1) production 构建本地可复现（等价 CI 的 jekyll build 步骤）
docker exec sdwycgithubio-jekyll-1 bash -c \
  "cd /srv/jekyll && JEKYLL_ENV=production bundle exec jekyll build -d /tmp/prod_site"
# → exit 0，done in 100.336 seconds

# 2) 检查新版本是否需要更高 Node
curl -s https://registry.npmjs.org/purgecss/9.1.0 | jq .engines
# → {"node": ">=22.12.0"}
```

---

## 2026-11-20 20:53 实际推送后的真实报错（本文件第一节的结论需修正）

推送 commit `443d652` 后，Actions 立刻暴露出**真实失败**（此前 API 里看不到，因为历史 run 已过保留期）：

| 运行 | event | 结果 |
|---|---|---|
| Deploy site | push | **failure** |
| `.github/workflows/docker-slim.yml` | push | **failure（0 个 job）** |
| Docker Image CI / broken links | push | skipped（上游门禁） |

### 报错原文（Deploy site → Setup Ruby 💎）

```
[command]/opt/hostedtoolcache/Ruby/3.3.5/x64/bin  (PATH 已设置)
Downloading Ruby
https://github.com/ruby/ruby-builder/releases/download/ruby-3.3.5/ruby-3.3.5-ubuntu-26.04-x64.tar.gz
##[error]Error: Unavailable version 3.3.5 for ruby on ubuntu-26.04
Only the latest patch release of each series is built for newer runner images.
ruby-3.3.14 is available on ubuntu-26.04: use ruby-version: '3.3.14', or '3.3' to always use the latest 3.3.x release.
Cause: Unexpected HTTP response: 404
```

### 原因分析

1. **`ubuntu-latest` 已滚动到 ubuntu-26.04**，而 ruby-builder 只为新镜像编译**每个系列的最新补丁版**
   （3.3 系列现为 3.3.14）。`ruby-version: "3.3.5"` 这种精确到补丁的写法在新镜像上必然 404，
   属于"写死版本"与"runner 镜像滚动"的冲突。CI 在第 3 步就失败，后面全部 skipped。

2. **`docker-slim.yml` 每次 push 都产生一条 0 job 的失败记录**，且 Actions 列表里它的名字显示为
   文件路径（而不是 `Docker Slim`）—— 这是 GitHub 解析该 workflow 失败的典型特征。
   该文件只做上游发布（`amirpourmand/al-folio`）且 job 带
   `if: github.repository_owner == 'alshedivat'`，在本仓库**永远不可能成功**。

### 改动做法

```diff
# deploy.yml
-          ruby-version: "3.3.5"
+          ruby-version: "3.3"
# axe.yml / broken-links-site.yml（同样问题，值是 3.2.2）
-          ruby-version: "3.2.2"
+          ruby-version: "3.2"
# 删除上游专用、无法解析的工作流
- .github/workflows/docker-slim.yml
```

为什么用系列号 `3.3` 而不是精确锁 `3.3.14`：gem 版本已由 `Gemfile.lock` 硬锁，
Ruby 补丁号漂移不影响依赖解析；而写死补丁号会在 ruby-builder 更新补丁后**再次 404**。
上游 release 提示也明确推荐 `'3.3'`。

### 验证方式

推 `443d652` 后 API 读取运行结果（这是唯一可信的验证，本地构建通过不代表 CI 通过）：

```bash
curl -s "https://api.github.com/repos/sdwyc/sdwyc.github.io/actions/runs?per_page=20"
# 443d652: Deploy site -> failure（Setup Ruby）
#          docker-slim.yml -> failure（0 jobs）

# 拉具体失败 step 的日志（需 token，且必须用 Authorization: token，Bearer 会 401）
curl -s -H "Authorization: token $GH" \
  "https://api.github.com/repos/.../actions/runs/44738319712/jobs"   # 定位到 step 3
curl -sL "$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Authorization: token '$GH \
  'https://api.github.com/repos/.../actions/jobs/<jobid>/logs')"      # 302 → blob，拿到纯文本日志
```

### 影响面 / 回滚

- 影响：CI 的 Ruby 选择方式、移除 1 个无用工作流；站点构建产物逻辑不变。
- 回滚：`git revert d4f38e2 d550830`。
- 遗留：CodeQL 仍处于 `disabled_inactivity`（服务端状态），需人工 Enable。

---

### 影响面 / 回滚

- 影响：仅 `Deploy site` 工作流的第 3、4 个 step；不改变站点产物逻辑。
- CodeQL 被服务端停用的问题本次**未修复**（需人工点 Enable 或提供 token 调用 API）。
- 回滚：`git revert` 对应 commit 即可；或把 purgecss 版本改回无约束。
- 顺带记录：CI 用 Ruby 3.3.5，本地 Docker 用 3.2.3，`Gemfile.lock` 在两个版本下都能解析
  （所有 gem 均为 3.2 兼容），故未改动 `ruby-version`，避免引入新变量。
