# Runner of the minimal test suite: psql from the PostgreSQL image and a script that writes JUnit.
ARG POSTGRES_IMAGE
FROM ${POSTGRES_IMAGE}
COPY --from=suite run.sh /opt/suite/run.sh
ENTRYPOINT ["bash", "/opt/suite/run.sh"]
