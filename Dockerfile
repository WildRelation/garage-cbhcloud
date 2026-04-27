FROM alpine:3.19

RUN apk add --no-cache wget

ARG GARAGE_VERSION=v1.0.0
RUN wget -O /usr/local/bin/garage \
    "https://garagehq.deuxfleurs.fr/download/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage" \
    && chmod +x /usr/local/bin/garage

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3900 3901 3902 3903

ENTRYPOINT ["/entrypoint.sh"]
CMD ["server"]
