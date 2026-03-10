<?php

/**
 * @file
 * Local development customizations.
 * 
 * In order for this file to be used, settings.local.php must be included
 * from settings.php. 
 * 
 * The following 3 lines in settings.php should be uncommented by the 
 * Dockerfile when the container is built, but if settings.default.php changes
 * in a future version the pattern may not match and you'll need to uncomment
 * them manually (or fix the Dockerfile):
 * 
 * if (file_exists($app_root . '/' . $site_path . '/settings.local.php')) {
 *   include $app_root . '/' . $site_path . '/settings.local.php';
 * }
 *
 * This file contains settings that are specific to the local Docker environment,
 * such as reverse proxy configurations and trusted host patterns. It is managed
 * in git and copied into place by the container's entrypoint script.
 */

// --- Database Credentials from Environment Variables ---
// Check for the DB_NAME environment variable and, if it exists, populate the
// $databases array for Drupal.
if (getenv('DB_NAME')) {
  $databases['default']['default'] = [
    'database' => getenv('DB_NAME'),
    'username' => getenv('DB_USER'),
    'password' => getenv('DB_PASSWORD'),
    'host' => getenv('DB_HOST'),
    'port' => getenv('DB_PORT') ?: '5432',
    'driver' => 'pgsql',
    'prefix' => '',
    'collation' => 'C',
  ];
}

// --- Read Password from Docker Secret ---
// Check if the secret file exists and override the password.
$secret_path = getenv('POSTGRES_PASSWORD_FILE') ?: '/run/secrets/drupal_cms-postgres_password';
if (file_exists($secret_path)) {
  $databases['default']['default']['password'] = trim(file_get_contents($secret_path));
}

// --- Configuration Sync Directory ---
// A path outside the web root, but within the persistent volume.
$settings['config_sync_directory'] = '../config/sync';

// --- Error Reporting ---
// Hide all error messages from the display.
$config['system.logging']['error_level'] = 'hide';

// Ensure errors are still sent to the system logs.
ini_set('log_errors', 'On');

// --- Trusted Host Patterns ---
$trusted_hosts = [];

// Add the primary domain from the DOMAIN environment variable
$domain = getenv('DOMAIN');
if ($domain) {
  $trusted_hosts[] = '^' . str_replace('.', '\.', $domain) . '$';
}

// Add any additional domains from the ADDITIONAL_TRUSTED_HOSTS environment variable
$additional_hosts = getenv('ADDITIONAL_TRUSTED_HOSTS');
if ($additional_hosts) {
  $host_list = explode(',', $additional_hosts);
  foreach ($host_list as $host) {
    $trusted_hosts[] = '^' . str_replace('.', '\.', trim($host)) . '$';
  }
}

if (!empty($trusted_hosts)) {
  $settings['trusted_host_patterns'] = $trusted_hosts;
}

// --- Reverse Proxy Settings ---
// Read the trusted proxy CIDR from an environment variable.
$trusted_proxy_cidr = getenv('TRUSTED_PROXY_CIDR') ?: '127.0.0.1';

$settings['reverse_proxy_addresses'] = [$trusted_proxy_cidr];
$settings['reverse_proxy'] = TRUE;
// Indicate which headers should be used to detect the original client IP and protocol.
$settings['reverse_proxy_trusted_headers'] = \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR;

// --- Guzzle HTTP Client Settings ---
// Force IPv4 to avoid Docker IPv6 timeout issues interacting with OpenAI.
$settings['http_client_config']['force_ip_resolve'] = 'v4';
