FROM alpine:3.5
MAINTAINER Andrew Usov "andrew.usov@youdowell.com"

RUN set -x && \
	apk add --no-cache --virtual=build-dependencies curl && \
    apk add --no-cache \
    		bash && \
    \
    curl -sSL -o /usr/local/bin/peer-finder https://storage.googleapis.com/kubernetes-release/pets/peer-finder && \
    chmod +x /usr/local/bin/peer-finder && \
    \
    apk del build-dependencies && rm -rf /tmp/*

WORKDIR "/opt/galera"
ADD ["galera/", "./"]

ENTRYPOINT ["peer-finder", "-on-start=/opt/galera/on-start.sh"]
CMD ["-service=mysql"]
