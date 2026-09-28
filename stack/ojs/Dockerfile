FROM php:8.3-fpm

# OJS 3.5 runtime deps:
# - mysqlnd/mysqli, gd, intl, mbstring, xml(+xsl), zip, curl, bcmath, soap (zip downloading), sockets
# - poppler-utils: pdftotext (OJS search indexing PDF)
# - msmtp: sendmail-compatible relay (email default = sendmail)
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev \
        libxslt1.1 libxslt1-dev libzip-dev libicu-dev \
        poppler-utils msmtp msmtp-mta ca-certificates \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli pdo_mysql gd intl xsl zip bcmath soap sockets pcntl opcache ftp \
    && rm -rf /var/lib/apt/lists/*

# PHP settings OJS needs (uploads besar, eksekusi lama)
RUN { \
        echo 'upload_max_filesize = 64M'; \
        echo 'post_max_size = 68M'; \
        echo 'memory_limit = 512M'; \
        echo 'max_execution_time = 120'; \
        echo 'max_input_time = 180'; \
        echo 'max_input_vars = 5000'; \
        echo 'expose_php = Off'; \
    } > /usr/local/etc/php/conf.d/ojs.ini \
    && { \
        echo 'opcache.enable = 1'; \
        echo 'opcache.memory_consumption = 192'; \
        echo 'opcache.validate_timestamps = 1'; \
        echo 'opcache.revalidate_freq = 2'; \
    } > /usr/local/etc/php/conf.d/opcache-tuned.ini

# sendmail → msmtp (default OJS email = sendmail); konfigurasi via env
# MSMTP_HOST/MSMTP_PORT/MSMTP_FROM di-set saat runtime, entrypoint menulis msmtprc.
RUN ln -sf /usr/bin/msmtp /usr/sbin/sendmail

# OJS tree lives at /var/www/ojs (www-data = uid 33)
COPY build/rootfs/etc/msmtprc /etc/msmtprc
COPY build/rootfs/etc/php-fpm.d/zz-ojs.conf /usr/local/etc/php-fpm.d/zz-ojs.conf
RUN chown www-data:www-data /etc/msmtprc && chmod 600 /etc/msmtprc

WORKDIR /var/www/biadenrekacipta/ojs
# Source mounted runtime (bind) pada path yang sama dengan host — nginx mengirim
# SCRIPT_FILENAME absolut host, jadi path di dalam container HARUS identik.
# cache/files writable oleh www-data
RUN install -d -o www-data -g www-data /var/www/biadenrekacipta/ojs/cache /var/www/biadenrekacipta/ojs-files

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD php -r '$f=@fsockopen("127.0.0.1",9000,$e,$s,3); if(!$f){fwrite(STDERR,"fpm not listening\n"); exit(1);} exit(0);'

ENTRYPOINT ["/usr/local/bin/docker-php-entrypoint"]
CMD ["php-fpm"]
