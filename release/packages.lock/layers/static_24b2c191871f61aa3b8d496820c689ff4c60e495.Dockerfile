ARG BASE_IMAGE
FROM $BASE_IMAGE
COPY . ./
RUN make static-assets