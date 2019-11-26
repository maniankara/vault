ARG BASE_IMAGE
FROM $BASE_IMAGE
COPY . ./
RUN cd ui && yarn run build