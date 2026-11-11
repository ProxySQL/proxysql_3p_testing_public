# ProxySQL runtime image for the PostgreSQL 3rd-party tests.
# Built once per run by pgsql/lib/package-image.sh from the .deb that 'make ubuntu24-dbg' produces;
# apt resolves the runtime dependencies from the package metadata.
ARG UBUNTU_IMAGE
FROM ${UBUNTU_IMAGE}

# the MySQL client talks to ProxySQL's admin interface (port 6032); separate layer so it caches locally
# apt retries each failed download itself; package-image.sh also retries the whole build
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# bind-mount instead of COPY: the package is installed, not also kept as an image layer
RUN --mount=type=bind,source=proxysql.deb,target=/tmp/proxysql.deb \
    apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends /tmp/proxysql.deb \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/lib/proxysql /tmp/gcov

# the build is gcov-instrumented: write coverage files to a scratch directory instead of the build path
ENV GCOV_PREFIX=/tmp/gcov

EXPOSE 6032 6133
# default config from the package; the test environment mounts its own /etc/proxysql.cnf
ENTRYPOINT ["proxysql", "-f", "-D", "/var/lib/proxysql"]
