# Lab 11 - a LOCAL stand-in for aws/codebuild/standard:7.0
#
# Floci 2.2.0 runs a CodeBuild build in a Docker container whose image is exactly the
# project's environment.image. "aws/codebuild/standard:7.0" is not a Docker Hub image
# (AWS serves it only inside CodeBuild), so the pull fails with
#   pull access denied for aws/codebuild/standard
# and every build ends FAULT before INSTALL.
#
# This image is tagged with that name on the local Docker daemon only, so the project
# document stays exactly what real AWS would accept. It carries just what buildspec.yml
# calls (bash, GNU sed, python3, coreutils, grep) - it is NOT the real CodeBuild image
# (Ubuntu 22.04 with many runtimes), and nothing built here should be read as proof of
# behaviour on that image.
#
#   docker build -t aws/codebuild/standard:7.0 labs/lab-11-cicd/codebuild-standin
FROM python:3.12-slim
LABEL org.opencontainers.image.description="USMS Lab 11 local stand-in for aws/codebuild/standard:7.0 - not the real image"
LABEL usms.lab="11"
