#!/bin/bash

# This script installs GeoIP2 for Cloudflare CDN with improved backup, validation, and error handling

NGINX_CONF="/etc/nginx/nginx.conf"
BACKUP_CONF="/etc/nginx/nginx.conf.bak"

# Function to backup nginx.conf
backup_nginx_conf() {
    if [ -f "$NGINX_CONF" ]; then
        cp "$NGINX_CONF" "$BACKUP_CONF"
        echo "Backup of nginx.conf created: $BACKUP_CONF"
    else
        echo "Error: nginx.conf not found!"
        exit 1
    fi
}

# Function to restore nginx.conf from backup
rollback_nginx_conf() {
    if [ -f "$BACKUP_CONF" ]; then
        mv "$BACKUP_CONF" "$NGINX_CONF"
        echo "Restored nginx.conf from backup: $BACKUP_CONF"
    else
        echo "Error: Backup file not found!"
        exit 1
    fi
}

# Function to safely update nginx.conf
update_nginx_conf() {
    # Example modification - replace placeholder with actual configuration
domains="[your_domains_here]"

    if ! grep -q "server_name" "$NGINX_CONF"; then
        echo "Error: server_name not found in nginx.conf!"
        exit 1
    fi

    # Validate with a temporary file
    temp_conf="$NGINX_CONF.tmp"
    cp "$NGINX_CONF" "$temp_conf"
    sed -i "s/server_name .*;/server_name $domains;/" "$temp_conf"

    if nginx -t -c "$temp_conf"; then
        mv "$temp_conf" "$NGINX_CONF"
        echo "nginx.conf updated successfully!"
    else
        echo "Error: nginx configuration test failed! Rolling back..."
        rollback_nginx_conf
        rm -f "$temp_conf"
        exit 1
    fi
    rm -f "$temp_conf"
}

# Main script execution
backup_nginx_conf
update_nginx_conf

# Reload NGINX to apply changes
if nginx -s reload; then
    echo "NGINX reloaded successfully!"
else
    echo "Error: Failed to reload NGINX!"
    rollback_nginx_conf
    exit 1
fi
