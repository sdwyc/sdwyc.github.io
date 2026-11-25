# 论文 Google Scholar 引用数一直显示 N/A

## 2026-11-25 22:15

- **文件**：`_plugins/google-scholar-citations.rb`、`_data/scholar_citations.yml`（新增）、
  `bin/update_scholar_citations.py`（新增）
- **改动**：插件从"构建期联网抓取"改为"读本地数据文件"；新增抓取脚本与数据文件

### 触发问题

部署后 `/publications/` 上每篇论文的 scholar 徽章都渲染成
`https://img.shields.io/badge/scholar-N/A-4285F4`，线上实测 9 处 `scholar-N/A`。

### 原因分析

原插件（`_plugins/google-scholar-citations.rb`）在 `render` 时请求**单篇文章**接口：

```
https://scholar.google.com/citations?view_op=view_citation&hl=en
  &user=<uid>&citation_for_view=<uid>:<cid>
```

实测该 URL 已返回 **302**，跳到 Google 反爬页面：

```
Location: https://www.google.com/sgsync?url=...&sg_fe=scife
```

插件把异常吞掉（`rescue Exception` → `citation_count = "N/A"`），所以构建不报错、
徽章却全是 N/A。在 GitHub Actions 的 runner IP 上更不可能拿到数据。

关键发现：**作者主页仍然可用**（200，152KB）：

```
https://scholar.google.com/citations?user=Us-5jAQAAAAJ&hl=en
```

页面里每行都带 `citation_for_view=<uid>:<cid>` 和 `<td class="gsc_a_c">33</td>`，
一次请求就能拿到全部论文的引用数。

### 改动做法

1. **`bin/update_scholar_citations.py`**（新增）：请求作者主页，逐行解析
   `citation_for_view` 里的 citation id 与 `gsc_a_c` 单元格里的数字，写出
   `_data/scholar_citations.yml`。解析到 0 行时直接非零退出（避免把空数据写进仓库）。
   user id 从 `_config.yml` 读，可用 `--userid` 覆盖。

2. **`_data/scholar_citations.yml`**（新增，由脚本生成）：

   ```yaml
   Us-5jAQAAAAJ:
     YsMSGLbcyi4C: 33
     9yKSN-GCB0IC: 23
     ...
   ```

3. **`_plugins/google-scholar-citations.rb`**（重写，约 60 行）：
   不再 `require 'nokogiri'/'open-uri'/'active_support'`，删掉 `sleep(rand(1.5..3.5))`
   与网络请求，改为 `site.data.dig("scholar_citations", userid)[article]`；
   缺失时打一条 warning 并返回 `N/A`。
   参数解析用 `Liquid::VariableLookup#evaluate`，同时兼容 `site.scholar_userid`
   这类普通变量和 `entry.google_scholar_id` 这类点路径。

   模板 `_layouts/bib.liquid` **未改动**，标签签名 `{% google_scholar_citations ... %}` 不变。

### 验证方式

```bash
# 1) 生成数据（15 条）
python3 bin/update_scholar_citations.py
# → Wrote 15 entries to _data/scholar_citations.yml

# 2) 校验 bib 覆盖：11 个 google_scholar_id 全部命中，缺失 0

# 3) 重启容器（_plugins 改动必须重启，watch 不生效）
docker compose restart

# 4) 抓渲染结果
curl -s http://localhost:8080/publications/ | grep -o 'badge/scholar-[0-9]*' | sort -u
# → scholar-1/2/3/4/7/14/23/33，scholar-N/A 计数为 0，日志无 Scholar: 警告
```

### 影响面 / 回滚

- 构建不再访问 Google Scholar：构建时间减少（原插件每次渲染 sleep 1.5–3.5s × 条目数 × 2），
  且不会因 429/反爬导致数据漂移。
- 新增依赖：无（脚本仅用标准库 urllib/re）。
- **维护约定**：论文或引用数变化后，需手动跑一次
  `python3 bin/update_scholar_citations.py` 并提交 `_data/scholar_citations.yml`。
  新增论文若忘了跑，徽章显示 N/A 且构建日志出现
  `Scholar: <uid>/<cid> is not in _data/scholar_citations.yml` 提示。
- 未做成定时 workflow：GitHub runner 的出口 IP 同样被判为机器人，定时任务大概率失败。
- 回滚：`git revert` 涉及提交即可，原插件从 git 历史恢复。
