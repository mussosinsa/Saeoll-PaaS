# Runtime image for a PHP application (Apache + mod_php).
# The pipeline sets BASE_REGISTRY to the Harbor "base-images" project; change
# the PHP version here only to images registered there (mirror-base-images.sh).
ARG BASE_REGISTRY=docker.io/library

FROM ${BASE_REGISTRY}/composer:2 AS vendor
# NEXUS_URL (build-arg): packages from the company Nexus (cicd-deps.sh); empty: packagist.org
ARG NEXUS_URL
ENV CICD_DEPS_DIR=/tmp/cicd-deps
WORKDIR /app
COPY cicd-deps.sh /tmp/cicd-deps.sh
COPY composer.json composer.lock* ./
RUN . /tmp/cicd-deps.sh && composer install --no-dev --no-interaction --no-progress --prefer-dist --no-scripts

# bookworm: the trixie images' xz (Landlock sandbox) fails under kaniko in docker-php-ext-install
#   ("xz: Failed to enable the sandbox")
FROM ${BASE_REGISTRY}/php:8.3-apache-bookworm
RUN docker-php-ext-install pdo_mysql opcache \
 && sed -ri 's!/var/www/html!/var/www/html/public!g' /etc/apache2/sites-available/*.conf \
 && sed -ri 's/Listen 80$/Listen 8080/; s/:80>/:8080>/' /etc/apache2/ports.conf /etc/apache2/sites-available/*.conf
WORKDIR /var/www/html
COPY --from=vendor /app/vendor ./vendor
COPY . .
RUN rm -rf k8s Jenkinsfile Dockerfile cicd-deps.sh \
 && chown -R www-data:www-data /var/www/html
USER www-data
EXPOSE 8080
