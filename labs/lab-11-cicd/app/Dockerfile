# The USMS enrolment service: a static portal served by nginx.
# The build context must already contain dist/, produced by buildspec.yml's build phase.
# Lab 12 Exercise 1: the base is a build argument, default unchanged, so a second base is
# `--build-arg BASE_IMAGE=...` rather than a second Dockerfile.
ARG BASE_IMAGE=nginx:1.27-alpine
FROM ${BASE_IMAGE}

# Copy the BUILT output, not the source tree.
COPY dist/ /usr/share/nginx/html/

# Lab 04's task definition health check fetches http://localhost/ and Lab 05's
# target group health check fetches / on the traffic port. Both need port 80.
EXPOSE 80

# nginx:alpine's own entrypoint already runs nginx in the foreground.
