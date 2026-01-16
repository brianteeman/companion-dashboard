#!/bin/bash
# Companion Dashboard Linux Server Installation Script (systemd version)
# This script installs and configures Companion Dashboard to run on Linux with systemd auto-start
# Uses systemd service instead of .bash_profile for more reliable auto-start across different OS versions

set -e

echo "=== Companion Dashboard Linux Server Installation (systemd) ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Get the actual user who invoked sudo
if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER=$SUDO_USER
else
    echo "Please run this script with sudo, not as root directly"
    exit 1
fi

INSTALL_DIR="/opt/companion-dashboard"
USER_HOME=$(eval echo ~$ACTUAL_USER)

echo "Installing for user: $ACTUAL_USER"
echo "Installation directory: $INSTALL_DIR"
echo ""

# Install required system packages
echo "Installing system dependencies..."
apt-get update
apt-get install -y \
    xorg \
    openbox \
    nodejs \
    npm \
    unclutter \
    x11-xserver-utils \
    libcap2-bin \
    avahi-daemon \
    avahi-utils

# Enable avahi for mDNS
systemctl enable avahi-daemon
systemctl start avahi-daemon

# Create installation directory
echo "Creating installation directory..."
mkdir -p $INSTALL_DIR
chown $ACTUAL_USER:$ACTUAL_USER $INSTALL_DIR

# Copy application files
echo "Locating application files..."
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if we have a built .deb file in multiple locations
echo "Searching for .deb package..."
DEB_FILE=""

# First check: Same directory as script (most common for SCP)
if [ -z "$DEB_FILE" ]; then
    DEB_FILE=$(ls -t "$SCRIPT_DIR"/"Companion.Dashboard"-*.deb 2>/dev/null | head -1)
    [ -n "$DEB_FILE" ] && echo "Found in script directory: $DEB_FILE"
fi

# Second check: out/ subdirectory (if running from project root)
if [ -z "$DEB_FILE" ]; then
    DEB_FILE=$(ls -t "$SCRIPT_DIR"/out/"Companion.Dashboard"-*.deb 2>/dev/null | head -1)
    [ -n "$DEB_FILE" ] && echo "Found in out/ directory: $DEB_FILE"
fi

if [ -n "$DEB_FILE" ]; then
    echo "Installing .deb package: $(basename "$DEB_FILE")"
    apt-get install -y "$DEB_FILE"
    if [ $? -eq 0 ]; then
        INSTALLED_VIA_DEB=true
        echo "✓ .deb package installed successfully"

        # Fix libffmpeg.so library path issue
        echo "Configuring library paths..."
        DASHBOARD_LIB_DIR=$(find /opt/"Companion Dashboard" /usr/lib/companion-dashboard -type d -name "lib" 2>/dev/null | head -1)
        if [ -z "$DASHBOARD_LIB_DIR" ]; then
            # If no lib directory, use the main installation directory
            DASHBOARD_LIB_DIR="/opt/Companion Dashboard"
        fi

        # Create ld.so.conf entry for Companion Dashboard libraries
        echo "$DASHBOARD_LIB_DIR" > /etc/ld.so.conf.d/companion-dashboard.conf
        ldconfig
        echo "✓ Library paths configured"
    else
        echo "✗ Failed to install .deb package"
        exit 1
    fi
else
    echo "No .deb package found. Attempting manual installation..."
    # Check if we have the required files for manual installation
    MISSING_FILES=false
    for file in dist src package.json; do
        if [ ! -e "$SCRIPT_DIR/$file" ]; then
            echo "⚠ Missing required file/directory: $file"
            MISSING_FILES=true
        fi
    done

    if [ "$MISSING_FILES" = true ]; then
        echo "✗ Manual installation failed: Missing required files"
        echo "Please ensure you have either:"
        echo "  1. A .deb file (Companion Dashboard-*.deb) in the same directory as this script, OR"
        echo "  2. All source files (dist, src, package.json) present"
        exit 1
    fi

    # Copy necessary files
    echo "Copying application files to $INSTALL_DIR..."
    cp -r "$SCRIPT_DIR"/{dist,src,package*.json} $INSTALL_DIR/
    chown -R $ACTUAL_USER:$ACTUAL_USER $INSTALL_DIR

    # Install dependencies
    echo "Installing Node.js dependencies..."
    cd $INSTALL_DIR
    sudo -u $ACTUAL_USER npm install --omit=dev
    if [ $? -eq 0 ]; then
        INSTALLED_VIA_DEB=false
        echo "✓ Manual installation completed successfully"
    else
        echo "✗ Failed to install Node.js dependencies"
        exit 1
    fi
fi

# Create startup script for display mode
echo "Creating startup script..."
cat > $INSTALL_DIR/start-display.sh << 'STARTSCRIPT_EOF'
#!/bin/bash
# Start Companion Dashboard in display mode (read-only, locked canvas)

cd "$(dirname "$0")"

# Set environment variables
export NODE_ENV=production
export DISPLAY=:0

# Log startup
echo "[$(date)] Starting Companion Dashboard in display mode..." >> /tmp/companion-dashboard.log

# Start the web server in the background
if [ -f /usr/bin/companion-dashboard ]; then
    # If installed via .deb
    /usr/bin/companion-dashboard --no-sandbox --kiosk-mode >> /tmp/companion-dashboard.log 2>&1 &
else
    # If installed manually
    npx electron . --no-sandbox --kiosk-mode >> /tmp/companion-dashboard.log 2>&1 &
fi

# Get the PID and wait for it to complete
ELECTRON_PID=$!
echo "[$(date)] Companion Dashboard started with PID $ELECTRON_PID" >> /tmp/companion-dashboard.log
wait $ELECTRON_PID
STARTSCRIPT_EOF

chmod +x $INSTALL_DIR/start-display.sh
chown $ACTUAL_USER:$ACTUAL_USER $INSTALL_DIR/start-display.sh

# Create .xinitrc for X server configuration
echo "Configuring X session..."
cat > $USER_HOME/.xinitrc << 'XINITRC_EOF'
#!/bin/bash
# Disable screen blanking and power management
xset s off
xset -dpms
xset s noblank

# Hide mouse cursor after 0.1 seconds of inactivity
unclutter -idle 0.1 -root &

# Start openbox window manager
openbox &

# Wait a moment for openbox to start
sleep 2

# Launch Companion Dashboard in display mode
if [ -f /opt/companion-dashboard/start-display.sh ]; then
    /opt/companion-dashboard/start-display.sh
else
    echo "ERROR: Companion Dashboard startup script not found"
fi
XINITRC_EOF

chown $ACTUAL_USER:$ACTUAL_USER $USER_HOME/.xinitrc
chmod +x $USER_HOME/.xinitrc

# Create systemd service for auto-start
echo "Creating systemd service..."
cat > /etc/systemd/system/companion-dashboard.service << SYSTEMD_EOF
[Unit]
Description=Companion Dashboard Display Service
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
User=$ACTUAL_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=$USER_HOME/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/startx $USER_HOME/.xinitrc -- :0 vt7
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
SYSTEMD_EOF

# Enable auto-login for the user
echo "Configuring auto-login..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << AUTOLOGIN_EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $ACTUAL_USER --noclear %I \$TERM
AUTOLOGIN_EOF

# Grant capability to bind to privileged ports (like port 80)
echo "Granting port 80 binding capability..."
if [ "$INSTALLED_VIA_DEB" = true ]; then
    # For .deb installation, find the actual electron binary
    ELECTRON_BINARY=""
    for path in "/opt/Companion Dashboard/companion-dashboard" "/opt/Companion Dashboard/chrome-sandbox" "/usr/lib/companion-dashboard/companion-dashboard"; do
        if [ -f "$path" ]; then
            ELECTRON_BINARY="$path"
            break
        fi
    done

    # If not found, search for it
    if [ -z "$ELECTRON_BINARY" ]; then
        ELECTRON_BINARY=$(find /opt /usr/lib -name "companion-dashboard" -type f -executable 2>/dev/null | grep -v ".sh$" | head -1)
    fi

    if [ -n "$ELECTRON_BINARY" ]; then
        setcap 'cap_net_bind_service=+ep' "$ELECTRON_BINARY"
        if getcap "$ELECTRON_BINARY" | grep -q cap_net_bind_service; then
            echo "✓ Capability granted to: $ELECTRON_BINARY"
        else
            echo "⚠ WARNING: Failed to set capability on $ELECTRON_BINARY"
            echo "  You may need to manually run: sudo setcap 'cap_net_bind_service=+ep' $ELECTRON_BINARY"
        fi
    else
        echo "⚠ WARNING: Could not find Electron binary. Port 80 may not work."
        echo "  After reboot, manually run: sudo setcap 'cap_net_bind_service=+ep' \$(which companion-dashboard)"
    fi
else
    # For manual installation, grant capability to node
    NODE_PATH=$(which node)
    if [ -n "$NODE_PATH" ]; then
        NODE_REAL=$(readlink -f "$NODE_PATH")
        setcap 'cap_net_bind_service=+ep' "$NODE_REAL"

        if getcap "$NODE_REAL" | grep -q cap_net_bind_service; then
            echo "✓ Capability granted to: $NODE_REAL"
        else
            echo "⚠ WARNING: Failed to set capability on $NODE_REAL"
        fi
    else
        echo "⚠ WARNING: Node.js not found. Installation may be incomplete."
    fi
fi

# Verify installation integrity
echo "Verifying installation..."
INSTALL_OK=true

if [ "$INSTALLED_VIA_DEB" = true ]; then
    if ! command -v companion-dashboard &> /dev/null; then
        echo "⚠ WARNING: companion-dashboard command not found in PATH"
        INSTALL_OK=false
    fi
else
    REQUIRED_DIRS=("$INSTALL_DIR/dist" "$INSTALL_DIR/src")
    for dir in "${REQUIRED_DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            echo "⚠ WARNING: Required directory missing: $dir"
            INSTALL_OK=false
        elif [ ! -r "$dir" ]; then
            echo "⚠ WARNING: Directory not readable: $dir"
            INSTALL_OK=false
        fi
    done

    if [ ! -d "$INSTALL_DIR/node_modules" ]; then
        echo "⚠ WARNING: node_modules directory missing. Dependencies may not be installed."
        INSTALL_OK=false
    fi
fi

# Ensure user directories exist with correct permissions
echo "Setting up user directories..."
sudo -u $ACTUAL_USER mkdir -p "$USER_HOME/.local/share"
sudo -u $ACTUAL_USER mkdir -p "$USER_HOME/.config"
sudo -u $ACTUAL_USER mkdir -p "$USER_HOME/.cache"

chown -R $ACTUAL_USER:$ACTUAL_USER "$USER_HOME/.local" 2>/dev/null || true
chown -R $ACTUAL_USER:$ACTUAL_USER "$USER_HOME/.config" 2>/dev/null || true
chown -R $ACTUAL_USER:$ACTUAL_USER "$USER_HOME/.cache" 2>/dev/null || true

# Enable and start the systemd service
echo "Enabling systemd service..."
systemctl daemon-reload
systemctl enable companion-dashboard.service

# Get local IP address
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
if [ "$INSTALL_OK" = true ]; then
    echo "=== Installation Complete! ✓ ==="
else
    echo "=== Installation Complete (with warnings) ==="
    echo "Please review the warnings above before rebooting."
fi
echo ""
echo "Installation method: systemd service"
echo ""
echo "The system will now automatically:"
echo "1. Boot to console and auto-login as $ACTUAL_USER"
echo "2. Start systemd service 'companion-dashboard.service'"
echo "3. Launch X server with Openbox window manager"
echo "4. Launch Companion Dashboard in read-only display mode (locked canvas)"
echo ""
echo "Access the dashboard from other devices at:"
echo "  http://dashboard.local (via mDNS)"
echo "  http://$LOCAL_IP (via IP address)"
echo ""
echo "Control view (full settings access):"
echo "  http://dashboard.local/control"
echo "  http://$LOCAL_IP/control"
echo ""
echo "To complete installation, reboot the system:"
echo "  sudo reboot"
echo ""
echo "Troubleshooting:"
echo "  - Check service status: sudo systemctl status companion-dashboard"
echo "  - View service logs: sudo journalctl -u companion-dashboard -f"
echo "  - View app logs: tail -f /tmp/companion-dashboard.log"
echo "  - Restart service: sudo systemctl restart companion-dashboard"
echo "  - Stop service: sudo systemctl stop companion-dashboard"
echo "  - Disable auto-start: sudo systemctl disable companion-dashboard"
echo "  - If display not showing, check: ps aux | grep companion-dashboard"
echo "  - View X server logs: cat ~/.local/share/xorg/Xorg.0.log"
echo "  - Check web server: curl http://localhost/"
echo "  - Verify port 80 capability: getcap \$(which node) or getcap \$(which companion-dashboard)"
echo "  - Test mDNS: avahi-browse -a"
echo ""
echo "GitHub: https://github.com/tomhillmeyer/companion-dashboard"
echo ""
