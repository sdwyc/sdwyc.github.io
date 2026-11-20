# =============================================================================
# al-folio 个人主页 —— 可复现构建镜像
#
# 版本策略：
#   1. 系统版本固定在 Ubuntu 24.04 LTS(noble)，由 UBUNTU_VERSION 控制；
#   2. Ruby / Bundler / Node 版本以 ARG 显式锁定，构建时校验，不符即失败；
#   3. 所有 gem 版本由 Gemfile.lock 固定（该文件已纳入版本控制）；
#      插件之间的版本适配在生成 lock 时一次性解析完成，构建期不再重新解析；
#   4. apt 包版本跟随 Ubuntu 24.04 归档（LTS 内的安全更新），不做逐包 pin，
#      避免归档旧版本下架后构建失败。
#
# 背景（历史修复，勿回退）：
#   - `ruby:latest` 已滚动到 Ruby 4.0，ostruct 被移出标准库，
#     jekyll-twitter-plugin 会 `cannot load such file -- ostruct` 直接崩溃；
#   - mini_racer 预编译二进制需 glibc >= 2.38，故改用 Node 作为 execjs 运行时。
# =============================================================================

ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

# ------------------------------- 版本锁定 ------------------------------------
# Ruby：Ubuntu 24.04 归档的 `ruby` 元包为 3.2.3
ARG RUBY_VERSION_REQUIRED=3.2
# Bundler：必须与 Gemfile.lock 中的 BUNDLED WITH 一致
ARG BUNDLER_VERSION=2.5.22
# Node：仅作为 execjs 的 JS 运行时（jekyll-minifier → terser），Ubuntu 24.04 为 18.19.1
ARG NODE_VERSION_REQUIRED=18

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    JEKYLL_ENV=production \
    EXECJS_RUNTIME=Node

# ------------------------------ 系统依赖 -------------------------------------
# ruby/ruby-dev：Ruby 3.2.3 及原生扩展编译头文件
# imagemagick : jekyll-imagemagick 生成响应式 webp（Ubuntu 版自带 libwebp delegate）
# nodejs      : execjs 运行时，取代 glibc 依赖脆弱的 mini_racer
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ruby \
        ruby-dev \
        build-essential \
        zlib1g-dev \
        libssl-dev \
        libyaml-dev \
        libffi-dev \
        imagemagick \
        nodejs \
        ca-certificates \
        curl \
        git \
        procps \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# ------------------------------ 版本校验 -------------------------------------
# 一旦 Ubuntu 归档中的版本发生变化，构建在此直接失败，避免悄悄跑偏
RUN set -eux; \
    ruby -v; \
    ruby -v | grep -q "ruby ${RUBY_VERSION_REQUIRED}\." \
        || { echo "ERROR: Ruby 版本与锁定值 ${RUBY_VERSION_REQUIRED} 不符"; exit 1; }; \
    node -v; \
    node -v | grep -q "^v${NODE_VERSION_REQUIRED}\." \
        || { echo "ERROR: Node 版本与锁定值 ${NODE_VERSION_REQUIRED} 不符"; exit 1; }; \
    convert -list format | grep -q "WEBP" \
        || { echo "ERROR: ImageMagick 缺少 WebP delegate"; exit 1; }

# ------------------------------- Bundler -------------------------------------
RUN gem install bundler -v "${BUNDLER_VERSION}" --no-document \
    && bundle "_${BUNDLER_VERSION}_" -v

# ------------------------------- 依赖安装 ------------------------------------
WORKDIR /srv/jekyll

# Gemfile.lock 已纳入版本控制；通配符保证 lock 缺失时（如临时克隆）也能构建
COPY Gemfile* ./

# 严格按 lock 安装，构建期不重新解析版本
RUN bundle install --jobs 4 --retry 5 \
    && rm -rf /var/lib/gems/*/cache/*.gem

EXPOSE 8080
EXPOSE 35729

COPY bin/entry_point.sh /tmp/entry_point.sh
RUN chmod +x /tmp/entry_point.sh

CMD ["/tmp/entry_point.sh"]
