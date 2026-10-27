# syntax=docker/dockerfile:1
# Brenmere hosted demo build shim. This public repo holds no application code:
# the source is cloned at build time from a PRIVATE repo with a read-only
# deploy key that Render supplies as a BuildKit secret (never stored in the
# image). DEMO_REF (a commit SHA, set on the Render service) busts the cache.
ARG RUBY_VERSION=3.4.8

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS src
ARG DEMO_REF=demo-render
ARG DEMO_REPO=git@github.com:tfnewcomb/brenmere-demo.git
RUN apt-get update -qq && apt-get install --no-install-recommends -y git openssh-client ca-certificates && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    echo "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > /root/.ssh/known_hosts
RUN --mount=type=secret,id=demo_deploy_key,dst=/root/.ssh/id_ed25519,required=true \
    git init -q /src && cd /src && \
    git -c core.sshCommand="ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -i /root/.ssh/id_ed25519" \
      fetch -q --depth 1 "$DEMO_REPO" "$DEMO_REF" && \
    git checkout -q FETCH_HEAD && git log -1 --format="demo source %H" && \
    rm -rf .git .kamal plans log/* tmp/* storage/* config/*.key config/credentials/*.key

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
WORKDIR /rails
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
ENV RAILS_ENV="demo" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY --from=src /src/Gemfile /src/Gemfile.lock /src/.ruby-version ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile
COPY --from=src /src /rails
RUN bundle exec bootsnap precompile -j 1 app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 SKIP_TAILWIND_BUILD=1 ./bin/rails assets:precompile

FROM base
# LibreOffice Writer (headless): Word drafts render in the Preview pane (app/lib/office_pdf.rb).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      python3 pipx pandoc libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz-subset0 fonts-liberation \
      libreoffice-writer-nogui && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install weasyprint==69.0 && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "markitdown[pdf,docx,xlsx,pptx]==0.1.5"
# eMudhra intermediate CA compromise (Oct 2026; Debian DSA-6572-1): take the
# fixed trust store (ca-certificates 20250419+deb13u1, NSS for LibreOffice) and
# the fixed Python certifi bundle (>= 2026.10.19, used by requests inside the
# markitdown venv). The build fails if an old trust store slips through.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends --only-upgrade -y ca-certificates libnss3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    update-ca-certificates --fresh > /dev/null && \
    dpkg --compare-versions "$(dpkg-query -W -f='${Version}' ca-certificates)" ge 20250419+deb13u1 && \
    ! ls /etc/ssl/certs/emSign_ECC_Root_CA_-_G3.pem /etc/ssl/certs/Comodo_AAA_Services_root.pem 2> /dev/null && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx inject --force markitdown "certifi>=2026.10.19" && \
    PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx runpip weasyprint install -q "certifi>=2026.10.19" && \
    for v in /opt/pipx/venvs/*; do "$v/bin/python" -c "import certifi,sys; print(sys.argv[1], certifi.__version__); assert certifi.__version__ >= '2026.10.19'; assert 'emSign ECC Root CA - G3' not in open(certifi.where()).read()" "$v"; done && \
    echo "trust store: ca-certificates $(dpkg-query -W -f='${Version}' ca-certificates)"
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
# Starts as root only to take ownership of the Render disk at /rails/storage,
# then bin/demo-entrypoint drops to the rails user (uid 1000).
ENTRYPOINT ["/rails/bin/demo-entrypoint"]
EXPOSE 10000
CMD ["./bin/thrust", "./bin/rails", "server"]
