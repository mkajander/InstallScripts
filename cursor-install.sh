#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Configuration Variables ---
APP_NAME="Cursor"
# API_URL for fetching the download link
API_URL="https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable"

# Installation and application paths
INSTALL_DIR="$HOME/.local/bin"
APP_IMAGE_FILENAME="$APP_NAME.AppImage"
APP_IMAGE_PATH="$INSTALL_DIR/$APP_IMAGE_FILENAME"

# Desktop entry and icon paths
DESKTOP_FILE_DIR="$HOME/.local/share/applications"
ICON_URL="https://us1.discourse-cdn.com/flex020/uploads/cursor1/original/2X/f/f7bc157cca4b97c3f0fc83c3c1a7094871a268df.png"
ICON_FILENAME="cursor-icon.png"
ICON_PATH="$HOME/.local/share/icons/$ICON_FILENAME"

# Update script and systemd service/timer file names and paths
UPDATE_SCRIPT_FILENAME="${APP_NAME}-update-script.sh"
UPDATE_SCRIPT_PATH="$INSTALL_DIR/$UPDATE_SCRIPT_FILENAME"
SERVICE_FILE_NAME="${APP_NAME}-update.service"
SERVICE_FILE_PATH="$HOME/.config/systemd/user/$SERVICE_FILE_NAME"
TIMER_FILE_NAME="${APP_NAME}-update.timer"
TIMER_FILE_PATH="$HOME/.config/systemd/user/$TIMER_FILE_NAME"

# --- Helper Functions ---

# Function to fetch the latest download URL for Cursor
fetch_latest_download_url() {
    # CORRECTED: Informational echo redirected to stderr
    echo "Fetching latest $APP_NAME download URL from $API_URL..." >&2
    local download_url
    local curl_stderr
    local curl_stdout
    
    CURL_STDERR_TMP=$(mktemp)
    
    # Execute curl and capture its stdout; redirect its stderr to the temp file
    # -sSL: silent, show errors, follow redirects
    curl_stdout=$(curl -sSL --stderr "$CURL_STDERR_TMP" "$API_URL")
    curl_exit_code=$?
    curl_stderr=$(<"$CURL_STDERR_TMP")
    rm -f "$CURL_STDERR_TMP"

    if [ $curl_exit_code -ne 0 ]; then
        echo "Error: curl command failed while fetching API data. Exit code: $curl_exit_code." >&2
        if [ -n "$curl_stderr" ]; then
            echo "curl stderr: $curl_stderr" >&2
        fi
        return 1
    fi

    download_url=$(echo "$curl_stdout" | jq -r '.downloadUrl')

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        echo "Error: Failed to get download URL from API. Raw API response was:" >&2
        echo "$curl_stdout" >&2
        if [ -n "$curl_stderr" ]; then # Also print curl's stderr if any
            echo "curl stderr (if any from API call): $curl_stderr" >&2
        fi
        return 1
    fi
    echo "$download_url" # This is the return value (the URL itself) to stdout
    return 0
}

# --- Main Script ---

echo "Starting installation/update process for $APP_NAME..."

# Step 1: Install jq if not present
if ! command -v jq &> /dev/null; then
    echo "jq (JSON parser) is not installed. Attempting to install..."
    if command -v sudo &> /dev/null && command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y jq
        if ! command -v jq &> /dev/null; then
            echo "Error: Failed to install jq. Please install it manually and re-run the script." >&2
            exit 1
        fi
        echo "jq installed successfully."
    else
        echo "Error: sudo or apt-get not found. Cannot auto-install jq." >&2
        echo "Please install jq manually (e.g., 'sudo apt install jq') and re-run the script." >&2
        exit 1
    fi
else
    echo "jq is already installed."
fi

# Step 2: Create necessary directories
echo "Creating necessary directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$DESKTOP_FILE_DIR"
mkdir -p "$(dirname "$ICON_PATH")"
mkdir -p "$(dirname "$SERVICE_FILE_PATH")"

# Step 3: Fetch the actual download URL
# APP_IMAGE_DOWNLOAD_URL will now correctly contain *only* the URL
APP_IMAGE_DOWNLOAD_URL=$(fetch_latest_download_url)
if [ $? -ne 0 ]; then
    echo "Exiting due to failure in fetching download URL." >&2
    exit 1
fi
echo "Successfully fetched download URL: $APP_IMAGE_DOWNLOAD_URL"

# Step 4: Download Cursor AppImage
echo "Downloading $APP_NAME AppImage from $APP_IMAGE_DOWNLOAD_URL to $APP_IMAGE_PATH..."
TEMP_APP_IMAGE_PATH="${APP_IMAGE_PATH}.tmp"
# Use curl with -f to fail on server errors, -L to follow redirects, -o to specify output
if curl -fL "$APP_IMAGE_DOWNLOAD_URL" -o "$TEMP_APP_IMAGE_PATH"; then
    echo "$APP_NAME AppImage downloaded to temporary file."
else
    echo "Error: Failed to download $APP_NAME AppImage. curl exit code: $?" >&2
    rm -f "$TEMP_APP_IMAGE_PATH" # Clean up temp file if it exists
    exit 1
fi

if [ ! -s "$TEMP_APP_IMAGE_PATH" ]; then
    echo "Error: Downloaded AppImage file is empty. Check the URL or network." >&2
    rm -f "$TEMP_APP_IMAGE_PATH"
    exit 1
fi

mv "$TEMP_APP_IMAGE_PATH" "$APP_IMAGE_PATH"
echo "$APP_NAME AppImage moved to $APP_IMAGE_PATH."

# Step 5: Make the AppImage executable
chmod +x "$APP_IMAGE_PATH"
echo "$APP_NAME AppImage made executable."

# Step 6: Download the icon
echo "Downloading $APP_NAME icon from $ICON_URL to $ICON_PATH..."
if curl -fL "$ICON_URL" -o "$ICON_PATH"; then
    echo "$APP_NAME icon downloaded."
else
    echo "Warning: Failed to download $APP_NAME icon. curl exit code: $?. You might need to set it manually." >&2
fi

# Step 7: Create a desktop entry
echo "Creating desktop entry at $DESKTOP_FILE_DIR/$APP_NAME.desktop..."
cat > "$DESKTOP_FILE_DIR/$APP_NAME.desktop" <<EOL
[Desktop Entry]
Version=1.0
Name=$APP_NAME
Comment=A code editor for building software, with AI built-in.
Exec=$APP_IMAGE_PATH --no-sandbox %U
Icon=$ICON_PATH
Terminal=false
Type=Application
Categories=Development;Utility;TextEditor;IDE;
MimeType=text/plain;inode/directory;application/x-zerosize;
StartupWMClass=cursor
Keywords=Text;Editor;Development;Programming;AI;Code;
EOL
echo "Desktop entry created."

# Step 8: Create the update script that systemd will run
echo "Creating update script at $UPDATE_SCRIPT_PATH..."
cat > "$UPDATE_SCRIPT_PATH" <<EOL
#!/bin/bash
set -e

APP_NAME="${APP_NAME}"
API_URL="${API_URL}"
APP_IMAGE_PATH="${APP_IMAGE_PATH}"
LOG_PREFIX="[\$APP_NAME Update Script] "

echo "\${LOG_PREFIX}Starting update check..." >&2 # Informational to stderr

# Ensure jq is available
if ! command -v jq &> /dev/null; then
    echo "\${LOG_PREFIX}Error: jq is not installed. Update cannot proceed." >&2
    echo "\${LOG_PREFIX}Please run the main installation script again or install jq manually." >&2
    if command -v notify-send &> /dev/null; then
        notify-send --urgency=critical "\$APP_NAME Update Failed" "jq is not installed. Please re-run installer or install jq."
    fi
    exit 1
fi

echo "\${LOG_PREFIX}Fetching latest download URL from \$API_URL..." >&2 # Informational to stderr
# Use a local function for clarity, similar to the main script
fetch_update_url() {
    local _api_url="\$1"
    local _download_url
    local _curl_stdout
    _curl_stdout=\$(curl -sSL "\$_api_url") # -sSL for silent, show error, follow redirects
    _curl_exit_code=\$?

    if [ \$_curl_exit_code -ne 0 ]; then
        echo "\${LOG_PREFIX}Error: curl command failed while fetching API for update. Exit code: \$_curl_exit_code." >&2
        return 1
    fi

    _download_url=\$(echo "\$_curl_stdout" | jq -r '.downloadUrl')

    if [ -z "\$_download_url" ] || [ "\$_download_url" = "null" ]; then
        echo "\${LOG_PREFIX}Error: Failed to get download URL from API for update. Raw API response:" >&2
        echo "\$_curl_stdout" >&2
        return 1
    fi
    echo "\$_download_url" # Only URL to stdout
    return 0
}

LATEST_DOWNLOAD_URL=\$(fetch_update_url "\$API_URL")
if [ \$? -ne 0 ]; then
    echo "\${LOG_PREFIX}Failed to fetch latest download URL for update. Exiting." >&2
    if command -v notify-send &> /dev/null; then
        notify-send --urgency=normal "\$APP_NAME Update Failed" "Could not fetch new version URL."
    fi
    exit 1
fi

echo "\${LOG_PREFIX}Current AppImage path: \$APP_IMAGE_PATH" >&2
echo "\${LOG_PREFIX}New download URL: \$LATEST_DOWNLOAD_URL" >&2

echo "\${LOG_PREFIX}Downloading updated AppImage to a temporary file..." >&2
TEMP_UPDATE_PATH="\${APP_IMAGE_PATH}.tmp_update"

if curl -fL "\$LATEST_DOWNLOAD_URL" -o "\$TEMP_UPDATE_PATH"; then
    echo "\${LOG_PREFIX}Download successful." >&2
else
    echo "\${LOG_PREFIX}Error: Failed to download updated AppImage. curl exit code: \$?" >&2
    rm -f "\$TEMP_UPDATE_PATH"
    if command -v notify-send &> /dev/null; then
        notify-send --urgency=normal "\$APP_NAME Update Failed" "Download of new version failed."
    fi
    exit 1
fi

if [ ! -s "\$TEMP_UPDATE_PATH" ]; then
    echo "\${LOG_PREFIX}Error: Downloaded updated file is empty for \$APP_NAME." >&2
    rm -f "\$TEMP_UPDATE_PATH"
    if command -v notify-send &> /dev/null; then
        notify-send --urgency=normal "\$APP_NAME Update Failed" "Downloaded update file was empty."
    fi
    exit 1
fi

mv "\$TEMP_UPDATE_PATH" "\$APP_IMAGE_PATH"
chmod +x "\$APP_IMAGE_PATH"
echo "\${LOG_PREFIX}\$APP_NAME has been updated successfully!" >&2 # To stderr for logging
if command -v notify-send &> /dev/null; then
    notify-send "\$APP_NAME Updated" "\$APP_NAME has been successfully updated to the latest version."
fi
EOL
chmod +x "$UPDATE_SCRIPT_PATH"
echo "Update script created and made executable."

# Step 9: Create systemd service file
echo "Creating systemd service file at $SERVICE_FILE_PATH..."
cat > "$SERVICE_FILE_PATH" <<EOL
[Unit]
Description=Update $APP_NAME AppImage
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $UPDATE_SCRIPT_PATH
Environment="DISPLAY=:0"
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
Environment="PATH=/usr/bin:/bin:\$HOME/.local/bin"

[Install]
WantedBy=default.target
EOL
echo "Systemd service file created."

# Step 10: Create systemd timer file
echo "Creating systemd timer file at $TIMER_FILE_PATH..."
cat > "$TIMER_FILE_PATH" <<EOL
[Unit]
Description=Daily update check for $APP_NAME AppImage
RefuseManualStart=no
RefuseManualStop=no

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOL
echo "Systemd timer file created."

# Step 11: Reload systemd, enable and start the timer
echo "Reloading systemd user daemon, enabling and starting $TIMER_FILE_NAME..."
systemctl --user daemon-reload
systemctl --user enable --now "$TIMER_FILE_NAME"

if systemctl --user is-active "$TIMER_FILE_NAME" > /dev/null; then
    echo "$TIMER_FILE_NAME is active."
    echo "To see next run time: systemctl --user list-timers $TIMER_FILE_NAME"
else
    echo "Warning: $TIMER_FILE_NAME might not be active. Check with: systemctl --user status $TIMER_FILE_NAME" >&2
fi
if systemctl --user status "$SERVICE_FILE_NAME" &> /dev/null && systemctl --user status "$SERVICE_FILE_NAME" | grep -q "failed"; then
    echo "Warning: The service $SERVICE_FILE_NAME may have issues. Check with: systemctl --user status $SERVICE_FILE_NAME" >&2
    echo "And logs: journalctl --user -u $SERVICE_FILE_NAME" >&2
fi

# Step 12: Update desktop database
echo "Updating desktop database..."
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database -q "$DESKTOP_FILE_DIR"
    echo "Desktop database updated."
else
    echo "update-desktop-database command not found. You may need to log out/in or run it manually."
fi

# Step 13: Notify the user
echo ""
echo "$APP_NAME has been installed/updated successfully!"
echo "-----------------------------------------------------"
echo "You can launch it from your application menu or by running:"
echo "  $APP_IMAGE_PATH"
echo ""
echo "Automatic daily updates are scheduled via systemd user timer."
echo "  Check timer status: systemctl --user list-timers | grep $APP_NAME"
echo "  Check service logs: journalctl --user -u $SERVICE_FILE_NAME -f"
echo "  Manually trigger update: $UPDATE_SCRIPT_PATH"
echo "  Or run the service: systemctl --user start $SERVICE_FILE_NAME"
echo "-----------------------------------------------------"

exit 0
