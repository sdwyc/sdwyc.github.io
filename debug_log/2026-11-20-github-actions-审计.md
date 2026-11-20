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

### 影响面 / 回滚

- 影响：仅 `Deploy site` 工作流的第 3、4 个 step；不改变站点产物逻辑。
- CodeQL 被服务端停用的问题本次**未修复**（需人工点 Enable 或提供 token 调用 API）。
- 回滚：`git revert` 对应 commit 即可；或把 purgecss 版本改回无约束。
- 顺带记录：CI 用 Ruby 3.3.5，本地 Docker 用 3.2.3，`Gemfile.lock` 在两个版本下都能解析
  （所有 gem 均为 3.2 兼容），故未改动 `ruby-version`，避免引入新变量。
