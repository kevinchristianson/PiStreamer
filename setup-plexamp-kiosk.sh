#!/bin/bash
# =============================================================================
# Plexamp Kiosk Setup Script v2
# Run this from your host machine:
#   bash setup-plexamp-kiosk.sh <pi-hostname-or-ip> <username>
# Example:
#   bash setup-plexamp-kiosk.sh plexpi.local kevin
#
# Prerequisites:
#   - Raspberry Pi OS Lite (64-bit) freshly flashed
#   - SSH enabled (via Raspberry Pi Imager advanced options)
#   - Pi connected to network
#   - Host machine has ssh and scp available
#
# After the script completes you will need to manually:
#   1. SSH into the Pi and run: node ~/plexamp/js/index.js
#      to get a claim token, then visit https://plex.tv/claim
#   2. The script will pause and wait for you to complete this step
#   3. On first kiosk boot: temporarily disable --kiosk in sway config
#      to complete Plexamp web UI sign-in (instructions printed at end)
# =============================================================================

set -e

PI_HOST="${1:?Usage: $0 <pi-hostname-or-ip> <username>}"
PI_USER="${2:?Usage: $0 <pi-hostname-or-ip> <username>}"
SSH="ssh ${PI_USER}@${PI_HOST}"

echo ""
echo "============================================="
echo " Plexamp Kiosk Setup v2"
echo " Host: ${PI_HOST}"
echo " User: ${PI_USER}"
echo "============================================="
echo ""

# -----------------------------------------------------------------------------
echo "[1/11] Updating system..."
# -----------------------------------------------------------------------------
$SSH "sudo apt update && sudo apt full-upgrade -y"

# -----------------------------------------------------------------------------
echo "[2/11] Installing dependencies..."
# -----------------------------------------------------------------------------
$SSH "sudo apt install -y \
    alsa-utils \
    curl \
    sway \
    chromium \
    swayidle \
    playerctl \
    libgl1-mesa-dri"

# -----------------------------------------------------------------------------
echo "[3/11] Installing Node.js 20..."
# -----------------------------------------------------------------------------
$SSH "curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs"
$SSH "node --version"

# -----------------------------------------------------------------------------
echo "[4/11] Downloading and installing Plexamp headless..."
# -----------------------------------------------------------------------------
# Check https://plexamp.com/#headless for the latest version and update URL if needed
PLEXAMP_URL="https://plexamp.plex.tv/headless/Plexamp-Linux-headless-v4.10.1.tar.bz2"
PLEXAMP_TAR="Plexamp-Linux-headless-v4.10.1.tar.bz2"

$SSH "
    cd ~ &&
    wget -q --show-progress ${PLEXAMP_URL} &&
    tar -xjf ${PLEXAMP_TAR} &&
    rm ${PLEXAMP_TAR}
"

# Verify plexamp extracted correctly
$SSH "ls ~/plexamp/js/index.js" || { echo "ERROR: Plexamp extraction failed"; exit 1; }

# -----------------------------------------------------------------------------
echo "[5/11] Creating wait-for-alsa script..."
# -----------------------------------------------------------------------------
$SSH 'tee ~/wait-for-alsa.sh > /dev/null << '"'"'EOF'"'"'
#!/bin/bash
until aplay -l &>/dev/null && aplay -l | grep -q "card"; do
    sleep 1
done
EOF'
$SSH "chmod +x ~/wait-for-alsa.sh"

# -----------------------------------------------------------------------------
echo "[6/11] Creating Plexamp systemd service..."
# -----------------------------------------------------------------------------
$SSH "sudo tee /etc/systemd/system/plexamp.service > /dev/null << EOF
[Unit]
Description=Plexamp Headless
After=network.target sound.target

[Service]
User=${PI_USER}
ExecStartPre=/home/${PI_USER}/wait-for-alsa.sh
ExecStart=/usr/bin/node /home/${PI_USER}/plexamp/js/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

$SSH "sudo systemctl daemon-reload && sudo systemctl enable plexamp"

# -----------------------------------------------------------------------------
echo "[7/11] Claiming Plexamp..."
# -----------------------------------------------------------------------------
echo ""
echo "---------------------------------------------"
echo " MANUAL STEP REQUIRED"
echo "---------------------------------------------"
echo " Open a new terminal, SSH into your Pi and run:"
echo "   ssh ${PI_USER}@${PI_HOST}"
echo "   node ~/plexamp/js/index.js"
echo ""
echo " It will print a claim token. Visit:"
echo "   https://plex.tv/claim"
echo " Sign in with your Plex account and enter the token."
echo ""
echo " Then press Ctrl+C to stop Plexamp."
echo "---------------------------------------------"
read -p "Press Enter once you have claimed Plexamp..."

$SSH "sudo systemctl start plexamp"
sleep 3
$SSH "sudo systemctl status plexamp --no-pager" | grep -E "Active|Main PID"

# -----------------------------------------------------------------------------
echo "[8/11] Configuring auto-login..."
# -----------------------------------------------------------------------------
$SSH "sudo raspi-config nonint do_boot_behaviour B2"

# -----------------------------------------------------------------------------
echo "[9/11] Creating display management scripts..."
# -----------------------------------------------------------------------------

# Sleep display script - only sleeps if audio is not actively playing
$SSH 'tee ~/sleep-display.sh > /dev/null << '"'"'EOF'"'"'
#!/bin/bash
if grep -q "state: RUNNING" /proc/asound/card*/pcm*/sub*/status 2>/dev/null; then
    exit 0
fi
swaymsg "output * dpms off"
EOF'
$SSH "chmod +x ~/sleep-display.sh"

# Watch playback script - wakes display when playback starts
$SSH 'tee ~/watch-playback.sh > /dev/null << '"'"'EOF'"'"'
#!/bin/bash
LAST_STATE=""
while true; do
    if grep -q "state: RUNNING" /proc/asound/card*/pcm*/sub*/status 2>/dev/null; then
        CURRENT_STATE="playing"
    else
        CURRENT_STATE="stopped"
    fi

    if [ "$CURRENT_STATE" = "playing" ] && [ "$LAST_STATE" != "playing" ]; then
        swaymsg "output * dpms on"
    fi

    LAST_STATE="$CURRENT_STATE"
    sleep 2
done
EOF'
$SSH "chmod +x ~/watch-playback.sh"

# -----------------------------------------------------------------------------
echo "[10/11] Configuring sway kiosk..."
# -----------------------------------------------------------------------------
$SSH "mkdir -p ~/.config/sway"

$SSH "tee ~/.config/sway/config > /dev/null << EOF
# Hide cursor when idle
seat seat0 hide_cursor 3000

# Output config
output * bg #000000 solid_color

# Sleep display after 1 minute of inactivity if nothing is playing
exec swayidle -w \\\\
    timeout 60 '/home/${PI_USER}/sleep-display.sh' \\\\
    resume 'swaymsg \"output * dpms on\"'

# Wake display when playback starts
exec /home/${PI_USER}/watch-playback.sh

# Launch Chromium - waits for Plexamp to be ready first
exec bash -c 'until curl -s http://localhost:32500 > /dev/null; do sleep 1; done; chromium \\\\
    --kiosk \\\\
    --noerrdialogs \\\\
    --disable-infobars \\\\
    --no-first-run \\\\
    --touch-events=enabled \\\\
    --enable-features=UseOzonePlatform,WaylandTextInputV3 \\\\
    --ozone-platform=wayland \\\\
    --enable-wayland-ime \\\\
    --app=http://localhost:32500'

bar {
    mode invisible
}
EOF"

# -----------------------------------------------------------------------------
echo "[11/11] Configuring sway auto-start and user groups..."
# -----------------------------------------------------------------------------
$SSH 'grep -q "exec sway" ~/.profile || cat >> ~/.profile << '"'"'EOF'"'"'

if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
EOF'

$SSH "sudo usermod -aG video,render,tty ${PI_USER}"

# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo " Setup complete!"
echo "============================================="
echo ""
echo " IMPORTANT: One manual step remaining."
echo " The Plexamp web UI needs to be signed in to"
echo " from the kiosk display on first boot."
echo ""
echo " Steps:"
echo " 1. Reboot the Pi:"
echo "    ssh ${PI_USER}@${PI_HOST} 'sudo reboot'"
echo ""
echo " 2. After boot, SSH in and temporarily disable kiosk mode:"
echo "    ssh ${PI_USER}@${PI_HOST}"
echo "    nano ~/.config/sway/config"
echo "    Remove --kiosk and --app= from the Chromium exec line"
echo "    Then reload:"
echo "    SWAYSOCK=\$(ls /run/user/1000/sway*.sock | head -1) swaymsg reload"
echo ""
echo " 3. On the touch display, tap 'Sign In with Browser'"
echo "    Complete sign-in in the new tab that opens"
echo ""
echo " 4. SSH back in and restore --kiosk and --app= flags:"
echo "    nano ~/.config/sway/config"
echo "    SWAYSOCK=\$(ls /run/user/1000/sway*.sock | head -1) swaymsg reload"
echo ""
echo " 5. Reboot to confirm everything starts cleanly:"
echo "    sudo reboot"
echo ""
echo " ---- Audio Output ----"
echo " By default audio routes to the ALSA default device."
echo " Run 'aplay -l' on the Pi to list available devices."
echo " To route to a specific device, create /etc/asound.conf:"
echo "   sudo nano /etc/asound.conf"
echo "   defaults.pcm.!default {"
echo "       type hw"
echo "       card <card-name-from-aplay>"
echo "   }"
echo "   defaults.ctl.!default {"
echo "       type hw"
echo "       card <card-name-from-aplay>"
echo "   }"
echo ""
echo " ---- Access Plexamp from any browser ----"
echo " http://${PI_HOST}:32500"
echo "============================================="
