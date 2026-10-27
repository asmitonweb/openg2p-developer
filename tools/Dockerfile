# Renderer toolbox: helm (to template the charts) plus python/pyyaml (scripts/gen.py).
# Built once by oan.sh so the host needs nothing but Docker and git.
ARG HELM_IMAGE=alpine/helm:3.16.4
FROM ${HELM_IMAGE}
RUN apk add --no-cache bash curl python3 py3-yaml
ENTRYPOINT []
CMD ["bash"]
