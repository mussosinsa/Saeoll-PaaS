# Extends the K-PaaS pipeline Jenkins image with PHP build tooling:
#   php-cli + common extensions, Composer, buildah (image build/push) and kubectl.
# The base OS of cp-pipeline-jenkins is not assumed; the package manager is
# detected at build time (apt / dnf / microdnf / apk).
ARG BASE_IMAGE=registry.k-paas.org/kpaas/cp-pipeline-jenkins:v1.6.0
FROM ${BASE_IMAGE}

ARG ORIGINAL_USER=root
ARG KUBECTL_VERSION=v1.31.4

USER root

RUN set -eux; \
    if command -v apt-get >/dev/null; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        php-cli php-xml php-mbstring php-curl php-zip php-mysql php-intl php-gd php-bcmath \
        unzip git curl ca-certificates buildah fuse-overlayfs uidmap; \
      rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf >/dev/null || command -v microdnf >/dev/null; then \
      PM=$(command -v dnf || command -v microdnf); \
      $PM install -y php-cli php-xml php-mbstring php-pdo php-mysqlnd php-intl php-gd php-bcmath php-process \
        unzip git curl ca-certificates buildah fuse-overlayfs shadow-utils; \
      $PM clean all; \
    elif command -v apk >/dev/null; then \
      apk add --no-cache php83 php83-phar php83-openssl php83-mbstring php83-xml php83-dom php83-xmlwriter \
        php83-tokenizer php83-curl php83-zip php83-pdo_mysql php83-intl php83-gd php83-bcmath php83-ctype \
        php83-iconv php83-fileinfo unzip git curl ca-certificates buildah fuse-overlayfs shadow-uidmap; \
      [ -e /usr/bin/php ] || ln -s /usr/bin/php83 /usr/bin/php; \
    else \
      echo "Unsupported base image: no apt-get/dnf/microdnf/apk" >&2; exit 1; \
    fi; \
    php -v

# Composer (installer signature verified)
RUN set -eux; \
    expected=$(curl -fsSL https://composer.github.io/installer.sig); \
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php; \
    actual=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');"); \
    [ "$expected" = "$actual" ]; \
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; \
    rm -f /tmp/composer-setup.php; \
    composer --version

# kubectl (only if the base image does not ship one)
RUN set -eux; \
    if ! command -v kubectl >/dev/null; then \
      curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
      echo "$(curl -fsSL https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
      chmod +x /usr/local/bin/kubectl; \
    fi; \
    kubectl version --client

# buildah inside the (privileged) Jenkins pod: vfs storage and chroot
# isolation work without overlay mounts. Rootless use needs subuid ranges.
RUN set -eux; \
    mkdir -p /etc/containers; \
    printf '[storage]\ndriver = "vfs"\n' > /etc/containers/storage.conf; \
    if [ "${ORIGINAL_USER}" != "root" ] && [ "${ORIGINAL_USER}" != "0" ]; then \
      u=$(getent passwd "${ORIGINAL_USER}" | cut -d: -f1 || echo "${ORIGINAL_USER}"); \
      grep -q "^${u}:" /etc/subuid 2>/dev/null || echo "${u}:100000:65536" >> /etc/subuid; \
      grep -q "^${u}:" /etc/subgid 2>/dev/null || echo "${u}:100000:65536" >> /etc/subgid; \
    fi

ENV BUILDAH_ISOLATION=chroot \
    STORAGE_DRIVER=vfs \
    COMPOSER_ALLOW_SUPERUSER=1

USER ${ORIGINAL_USER}
