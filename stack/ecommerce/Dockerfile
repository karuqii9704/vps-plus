# Ecommerce (Laravel 13 + Livewire 4 + Flux) runtime.
# FPM only — the HOST nginx proxies to 127.0.0.1:9001 and serves
# /srv/repos/ecommerce/public directly (same absolute path inside the
# container, exactly like the OJS pattern on this box).
FROM composer:2 AS composer-bin

FROM php:8.4-fpm

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev \
        libzip-dev libicu-dev libonig-dev libpq-dev \
        unzip ca-certificates \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_pgsql pgsql gd zip intl mbstring bcmath exif pcntl sockets opcache \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer-bin /usr/bin/composer /usr/bin/composer

RUN { \
        echo 'upload_max_filesize = 32M'; \
        echo 'post_max_size = 36M'; \
        echo 'memory_limit = 512M'; \
        echo 'max_execution_time = 120'; \
        echo 'expose_php = Off'; \
        echo 'date.timezone = UTC'; \
    } > /usr/local/etc/php/conf.d/zz-ecommerce.ini \
    && { \
        echo 'opcache.enable = 1'; \
        echo 'opcache.memory_consumption = 192'; \
        echo 'opcache.validate_timestamps = 1'; \
        echo 'opcache.revalidate_freq = 2'; \
        echo 'opcache.max_accelerated_files = 20000'; \
    } > /usr/local/etc/php/conf.d/opcache-tuned.ini

COPY zz-ecommerce-fpm.conf /usr/local/etc/php-fpm.d/zz-ecommerce-fpm.conf

WORKDIR /srv/repos/ecommerce

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD php -r '$f=@fsockopen("127.0.0.1",9001,$e,$s,3); if(!$f){fwrite(STDERR,"fpm not listening\n"); exit(1);} exit(0);'

ENTRYPOINT ["/usr/local/bin/docker-php-entrypoint"]
CMD ["php-fpm"]
