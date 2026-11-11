# ProxySQL runtime image for the PostgreSQL 3rd-party tests.
# Built once per run by pgsql/lib/package-image.sh from the .deb that 'make ubuntu24-dbg' produces.
# Built without network access (--network=none): the image is exactly the pinned base image plus the
# ProxySQL package, whose only dependency (libgnutls30) is already in the base image. ProxySQL's admin
# interface is reached with psql over its PostgreSQL protocol port (6132), so no client is installed here.
ARG UBUNTU_IMAGE
FROM ${UBUNTU_IMAGE}

# bind-mount instead of COPY: the package is installed, not also kept as an image layer
RUN --mount=type=bind,source=proxysql.deb,target=/tmp/proxysql.deb \
    dpkg -i /tmp/proxysql.deb \
    && mkdir -p /var/lib/proxysql /tmp/gcov

# the build is gcov-instrumented: write coverage files to a scratch directory instead of the build path
ENV GCOV_PREFIX=/tmp/gcov

EXPOSE 6032 6132 6133
# default config from the package; the test environment mounts its own /etc/proxysql.cnf
ENTRYPOINT ["proxysql", "-f", "-D", "/var/lib/proxysql"]
