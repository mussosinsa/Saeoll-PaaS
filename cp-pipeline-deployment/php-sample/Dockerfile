# Runtime image for a PHP application (Apache + mod_php).
# PHP_BASE can point to a Harbor mirror when the cluster has no Docker Hub access.
ARG COMPOSER_IMAGE=docker.io/library/composer:2
ARG PHP_BASE=docker.io/library/php:8.3-apache

FROM ${COMPOSER_IMAGE} AS vendor
WORKDIR /app
COPY composer.json composer.lock* ./
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist --no-scripts

FROM ${PHP_BASE}
RUN docker-php-ext-install pdo_mysql opcache \
 && sed -ri 's!/var/www/html!/var/www/html/public!g' /etc/apache2/sites-available/*.conf \
 && sed -ri 's/Listen 80$/Listen 8080/; s/:80>/:8080>/' /etc/apache2/ports.conf /etc/apache2/sites-available/*.conf
WORKDIR /var/www/html
COPY --from=vendor /app/vendor ./vendor
COPY . .
RUN rm -rf k8s Jenkinsfile Dockerfile \
 && chown -R www-data:www-data /var/www/html
USER www-data
EXPOSE 8080
