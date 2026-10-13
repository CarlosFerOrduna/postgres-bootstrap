# Tooling image for scripts/pull.sh and scripts/restore.sh: Postgres client tools at the
# same version as the server, plus ssh and the docker CLI for ssh:/docker: sources.
ARG POSTGRES_IMAGE=postgres:16.3

FROM docker:27-cli AS docker-cli

FROM ${POSTGRES_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends openssh-client \
  && rm -rf /var/lib/apt/lists/*

# Static binary: runs on the postgres image's Debian base
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

ENV SNAPSHOT_IN_CONTAINER=1
WORKDIR /work

ENTRYPOINT ["bash", "/work/scripts/snapshot.sh"]
CMD ["help"]
