ARG NGINX_VER=1.24.0

FROM nginxinc/nginx-unprivileged:${NGINX_VER}-alpine as base
USER root
WORKDIR /opt

ARG GEO_DB_RELEASE=2023-05
ARG MODSEC_TAG=v3.0.9
ARG OWASP_TAG=v3.3.4

# Install dependencies; includes dependencies required for compile-time options:
# curl, libxml, pcre, and lmdb and Modsec
RUN echo "Installing Dependencies" && \
    apk add --no-cache --virtual general-dependencies \
    autoconf \
    automake \
    byacc \
    curl-dev \
    flex \
    g++ \
    gcc \
    geoip-dev \
    git \
    libc-dev \
    libmaxminddb-dev \
    libstdc++ \
    libtool \
    libxml2-dev \
    linux-headers \
    lmdb-dev \
    make \
    openssl-dev \
    pcre-dev \
    yajl-dev \
    zlib-dev

# Clone and compile modsecurity. Binary will be located in /usr/local/modsecurity
RUN echo "Installing ModSec Library" && \
    git clone -b ${MODSEC_TAG} --depth 1 https://github.com/SpiderLabs/ModSecurity && \
    git -C /opt/ModSecurity submodule update --init --recursive && \
    (cd "/opt/ModSecurity" && \
        ./build.sh && \
        ./configure --with-lmdb && \
        make && \
        make install \
    ) && \
    rm -fr /opt/ModSecurity \
        /usr/local/modsecurity/lib/libmodsecurity.a \
        /usr/local/modsecurity/lib/libmodsecurity.la

# Clone Modsec Nginx Connector, GeoIP, ModSec OWASP Rules, and download/extract nginx and GeoIP databases
RUN echo 'Cloning Modsec Nginx Connector, GeoIP, ModSec OWASP Rules, and download/extract nginx and GeoIP databases' && \
    git clone -b master --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git && \
    git clone -b master --depth 1 https://github.com/leev/ngx_http_geoip2_module.git && \
    git clone -b ${OWASP_TAG} --depth 1 https://github.com/coreruleset/coreruleset.git /usr/local/owasp-modsecurity-crs && \
    wget -O - https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz | tar -xz && \
    mkdir -p /etc/nginx/geoip && \
    wget -O - https://download.db-ip.com/free/dbip-city-lite-${GEO_DB_RELEASE}.mmdb.gz | gzip -d > /etc/nginx/geoip/dbip-city-lite.mmdb && \
    wget -O - https://download.db-ip.com/free/dbip-country-lite-${GEO_DB_RELEASE}.mmdb.gz | gzip -d > /etc/nginx/geoip/dbip-country-lite.mmdb

# Install GeoIP2 and ModSecurity Nginx modules
RUN echo 'Installing Nginx Modules' && \
    (cd "/opt/nginx-$NGINX_VERSION" && \
        ./configure --with-compat \
            --add-dynamic-module=../ModSecurity-nginx \
            --add-dynamic-module=../ngx_http_geoip2_module && \
        make modules \
    ) && \
    cp /opt/nginx-$NGINX_VERSION/objs/ngx_http_modsecurity_module.so \
        /opt/nginx-$NGINX_VERSION/objs/ngx_http_geoip2_module.so \
        /usr/lib/nginx/modules/ && \
    rm -fr /opt/* && \
    apk del general-dependencies

# fix for bitbucket issue
# failed to copy files: failed to copy directory: Error processing tar file(exit status 1): Container ID 165637 cannot be mapped to a host ID
RUN chown -R root:root /etc/nginx/ /usr/local/modsecurity /usr/local/owasp-modsecurity-crs /usr/lib/nginx/modules/

FROM nginxinc/nginx-unprivileged:${NGINX_VER}-alpine
USER root
WORKDIR /var/www/html

# Copy nginx, owasp-modsecurity-crs, and modsecurity from the build image
COPY --from=base --chown=nginx:nginx /etc/nginx/ /etc/nginx/
COPY --from=base --chown=nginx:nginx /usr/local/modsecurity /usr/local/modsecurity
COPY --from=base --chown=nginx:nginx /usr/local/owasp-modsecurity-crs /usr/local/owasp-modsecurity-crs
COPY --from=base --chown=nginx:nginx /usr/lib/nginx/modules/ /usr/lib/nginx/modules/

RUN apk add --no-cache \
    curl-dev \
    libmaxminddb-dev \
    libstdc++ \
    libxml2-dev \
    lmdb-dev \
    pcre \
    tzdata \
    yajl && \
    chown -R nginx:nginx /usr/share/nginx

COPY --chown=nginx:nginx main.conf /etc/nginx/modsec/
COPY --chown=nginx:nginx modsecurity.conf /etc/nginx/modsec/
COPY --chown=nginx:nginx unicode.mapping /etc/nginx/modsec/unicode.mapping
COPY --chown=nginx:nginx nginx.conf /etc/nginx/

RUN rm /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh && \
    mv /usr/local/owasp-modsecurity-crs/crs-setup.conf.example /usr/local/owasp-modsecurity-crs/crs-setup.conf
USER nginx
