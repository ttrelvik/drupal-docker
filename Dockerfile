# Stage 1: Build the application using a PHP base to ensure OS consistency.
# When updating the PHP version here, be sure to also update it in stage 2.
FROM php:8.4-fpm-bookworm AS builder

# Set the working directory for the build.
WORKDIR /app

# Install system dependencies needed for Composer and its plugins.
RUN apt-get update && apt-get install -y \
    git \
    unzip \
    libzip-dev \
    libpng-dev \
    libjpeg-dev \
    libwebp-dev \
    libpq-dev

# Install the required PHP extensions.
RUN docker-php-ext-configure gd --with-jpeg --with-webp
RUN docker-php-ext-install -j$(nproc) gd zip pgsql pdo_pgsql

# Install Composer globally.
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Create the project using the recommended project template.
# This aligns with the "Maintainable Core" strategy.
RUN composer create-project drupal/recommended-project:^11 . --no-install

# Add all enabled modules and dependencies.
RUN composer require \
    "drush/drush:^13" \
    "drupal/admin_toolbar:^3.6" \
    "drupal/add_content_by_bundle:^1.2" \
    "drupal/ai:^1.2" \
    "drupal/ai_agents:^1.2" \
    "drupal/ai_image_alt_text:^1.0" \
    "drupal/ai_provider_openai:^1.2" \
    "drupal/ai_seo:^1.0" \
    "drupal/ai_summarize_document:^1.1" \
    "drupal/ai_vdb_provider_postgres:^1.0@alpha" \
    "drupal/automatic_updates:^4.1" \
    "drupal/autosave_form:^1.10" \
    "drupal/better_exposed_filters:^7.1" \
    "drupal/bpmn_io:^3.0" \
    "drupal/captcha:^2.0" \
    "drupal/coffee:^2.0" \
    "drupal/crop:^2.5" \
    "drupal/dashboard:^2.2" \
    "drupal/drupal_cms_helper:^2.0" \
    "drupal/easy_breadcrumb:^2.0" \
    "drupal/easy_email:^3.0" \
    "drupal/eca:^3.0" \
    "drupal/focal_point:^2.1" \
    "drupal/friendlycaptcha:^1.1" \
    "drupal/gemini_provider:^1.0@beta" \
    "drupal/gin_toolbar:^3.0" \
    "drupal/honeypot:^2.2" \
    "drupal/jquery_ui:^1.8" \
    "drupal/jquery_ui_resizable:^2.1" \
    "drupal/key:^1.22" \
    "drupal/klaro:^3.0" \
    "drupal/linkit:^7.0" \
    "drupal/login_emailusername:^3.0" \
    "drupal/mailsystem:^4.5" \
    "drupal/menu_link_attributes:^1.6" \
    "drupal/metatag:^2.2" \
    "drupal/modeler_api:^1.0" \
    "drupal/pathauto:^1.14" \
    "drupal/project_browser:^2.1" \
    "drupal/redirect:^1.12" \
    "drupal/sam:^1.3" \
    "drupal/scheduler:^2.2" \
    "drupal/scheduler_content_moderation_integration:^3.0" \
    "drupal/search_api:^1.40" \
    "drupal/selective_better_exposed_filters:^3.0" \
    "drupal/svg_image:^3.2" \
    "drupal/symfony_mailer_lite:^2.0" \
    "drupal/tagify:^1.2" \
    "drupal/token:^1.17" \
    "drupal/trash:^3.0" \
    "drupal/drupal_cms_olivero:^1.2" \
    "drupal/easy_email_theme:^1.1" \
    "drupal/gin:^5.0" \
    --update-no-dev --no-install

# Now install all dependencies without dev packages and optimize the autoloader.
RUN composer install --no-dev --optimize-autoloader

# Stage 2: Build the production environment base. This is kept separate for clarity and caching.
FROM php:8.4-fpm-bookworm AS drupal_app_base

# Set environment variables for the application.
ENV PATH="/app/vendor/bin:$PATH"

# Install system dependencies. Note: 'git' is not needed in the final image.
RUN apt-get update && apt-get install -y \
    unzip \
    rsync \
    libzip-dev \
    libpng-dev \
    libjpeg-dev \
    libwebp-dev \
    libpq-dev \
    nginx \
    # Add dependencies needed to add the pgsql repo
    curl \
    gnupg \
    lsb-release && \
    # Add the PostgreSQL GPG key
    curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    # Add the PostgreSQL repository
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
    # Update apt lists again and install the specific client version
    apt-get update && \
    apt-get install -y postgresql-client-16

# Configure and install required PHP extensions for Drupal.
RUN docker-php-ext-configure gd --with-jpeg --with-webp
RUN docker-php-ext-install -j$(nproc) gd zip pdo pdo_pgsql pgsql opcache

# Increase PHP memory limit to accommodate vectordb indexing.
RUN echo "memory_limit = 512M" > /usr/local/etc/php/conf.d/memory-limit.ini

# Set up the application directory.
WORKDIR /app

# ---

# Stage 3: Build the final image.
FROM drupal_app_base AS final

# Copy the fully built Drupal application from the 'builder' stage.
COPY --from=builder /app .

# Copy your custom Nginx configuration and entrypoint script.
COPY .docker/nginx/default.conf /etc/nginx/sites-available/default
COPY .docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY .docker/drupal/settings.local.php /app/settings.local.php
COPY config /app/config/sync
COPY deploy.sh /app/deploy.sh
RUN chmod +x /app/deploy.sh /usr/local/bin/entrypoint.sh

# Prepare settings.php to include settings.local.php by default.
# This avoids manual edits after a container is created.
RUN sed -i "/# if (file_exists(\$app_root . '\/' . \$site_path . '\/settings.local.php'))/,+2s/^# //" /app/web/sites/default/default.settings.php

# Set ownership to the web user to avoid permission issues.
RUN chown -R www-data:www-data /app/web/sites

# Expose port 80 for the Nginx web server.
EXPOSE 80

# The entrypoint script will start PHP-FPM and Nginx.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]