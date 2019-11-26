ARG BASE_IMAGE
FROM $BASE_IMAGE
COPY . ./
RUN cd ui && yarn install
RUN cd ui && npm rebuild node-sass