#!/bin/bash
# 容器入口脚本
#
# 与旧版的关键差异：
# 1) 不再 `rm -f Gemfile.lock`。旧逻辑会在容器启动时删掉宿主机的 Gemfile.lock，
#    每次都重新解析依赖，既慢又造成版本漂移。
# 2) 使用 `bundle exec`，保证使用镜像内已安装的 gem，而不是系统的同名 gem。
# 3) 去掉 inotifywait 重启循环：macOS 上的 bind mount 收不到可靠 inotify 事件，
#    Jekyll 自身的 --watch/--force_polling 已能增量重建；改 _config.yml 后手动重启容器即可。
set -e

cd /srv/jekyll

echo "==> Ruby: $(ruby -v)"
echo "==> 检查依赖是否与 Gemfile.lock 一致 ..."

if ! bundle check >/dev/null 2>&1; then
  echo "==> 依赖不一致，按 Gemfile.lock 安装（不重新解析版本）..."
  bundle install --jobs 4 --retry 3
fi

echo "==> 启动 Jekyll: http://localhost:8080"
exec bundle exec jekyll serve \
  --source /srv/jekyll \
  --destination /srv/jekyll/_site \
  --host 0.0.0.0 \
  --port 8080 \
  --livereload \
  --force_polling \
  --watch \
  --trace
