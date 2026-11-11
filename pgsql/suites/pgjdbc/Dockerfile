# Runner of the pgJDBC suite. Build context: the upstream checkout at the pinned commit (unchanged);
# "suite": this folder. The test classes are compiled when the image is built, so the legs only run them.
ARG TEMURIN_IMAGE
FROM ${TEMURIN_IMAGE}
COPY . /opt/pgjdbc
WORKDIR /opt/pgjdbc
RUN ./gradlew --no-daemon --console plain --warning-mode=none :postgresql:testClasses
# after the compile step, so a change to these files does not recompile
COPY --from=suite run.sh init.gradle /opt/suite/
ENTRYPOINT ["bash", "/opt/suite/run.sh"]
