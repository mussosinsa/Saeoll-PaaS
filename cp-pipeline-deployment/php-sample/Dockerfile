# Runtime image for a PHP application (Apache + mod_php).
# The pipeline sets BASE_REGISTRY to the Harbor "base-images" project; change
# the PHP version here only to images registered there (mirror-base-images.sh).
ARG BASE_REGISTRY=docker.io/library

FROM ${BASE_REGISTRY}/composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock* ./
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist --no-scripts

FROM ${BASE_REGISTRY}/php:8.3-apache
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
