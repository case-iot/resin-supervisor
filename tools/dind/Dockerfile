FROM resin/resin-base

VOLUME /var/lib/docker
ENV DOCKER_VERSION 1.6.2

# From get.docker.com script
RUN apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9 \
	&& echo deb https://get.docker.com/ubuntu docker main > /etc/apt/sources.list.d/docker.list \
	&& apt-get update && apt-get install lxc-docker-${DOCKER_VERSION} \
	&& rm -rf /var/lib/apt/lists/*
	
RUN apt-get update && apt-get install jq \
	&& rm -rf /var/lib/apt/lists/*

COPY config/openvpn/ /etc/openvpn/
COPY config/services/ /etc/systemd/system/
COPY vpn-init /usr/src/app/

RUN systemctl enable resin-supervisor-dind