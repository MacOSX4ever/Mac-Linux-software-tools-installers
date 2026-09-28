#!/usr/bin/env bash
# -*- mode: shell-script -*-
# Self-contained build and deployment script for display-switcher with logging

[[ -z $RED ]] && source .ansi 2>/dev/null || true
[[ -z "$(which mytools)" ]] && echo "ERROR: mytools not found. Must be installed." && exit 1

RAW_OSTYPE=$(uname -s)
[[ "$RAW_OSTYPE" == *"MINGW"* || "$RAW_OSTYPE" == *"MSYS"* || "$RAW_OSTYPE" == *"CYGWIN"* || "$RAW_OSTYPE" == *"NT"* ]] && OSTYPE="Win" || OSTYPE="$RAW_OSTYPE"
ARCH=$(uname -m | tr '[:lower:]' '[:upper:]')

set -euo pipefail

# Setup logging: tee all stdout and stderr to both console and log file
LOG_FILE="$HOME/Desktop/display-switcher_install.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "==> Display-Switcher Installation Started: $(date)"
echo "=================================================="

APP_NAME="display-switcher"

# Pre-flight: Safely terminate running instances using OS-tailored exact matching
echo "==> Terminating any running instances of $APP_NAME..."
killall "$APP_NAME" || true

echo "==> Creating secure local temp build directory..."
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

cd "$BUILD_DIR"

echo "==> Generating Cargo.toml..."
cat << 'EOF' > Cargo.toml
[package]
name = "display-switcher"
version = "1.0.0"
edition = "2021"

[dependencies]
eframe = "0.29"
egui = "0.29"
EOF

echo "==> Generating Rust source files..."
mkdir -p src
cat << 'EOF' > src/main.rs
use eframe::egui;
use std::process::Command;

struct DisplaySwitcherApp {
    status_message: String,
}

impl Default for DisplaySwitcherApp {
    fn default() -> Self {
        Self {
            status_message: "Press 0-3, D, or click an input".to_string(),
        }
    }
}

impl DisplaySwitcherApp {
    fn switch_input(&mut self, name: &str, linux_code: &str, mac_code: &str) {
        let os = std::env::consts::OS;
        
        let (tool, args) = if os == "linux" {
            let resolved_path = Command::new("sh")
                .arg("-c")
                .arg("export PATH=\"/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH\"; which ddcutil || echo ddcutil")
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "ddcutil".to_string());
            
            let bin = if resolved_path.is_empty() { "ddcutil".to_string() } else { resolved_path };
            (bin, vec!["setvcp", "60", linux_code])
        } else if os == "macos" {
            let resolved_path = Command::new("sh")
                .arg("-c")
                .arg("export PATH=\"/opt/local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH\"; which ddcctl || echo ddcctl")
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_else(|_| "ddcctl".to_string());
            
            let bin = if resolved_path.is_empty() { "ddcctl".to_string() } else { resolved_path };
            (bin, vec!["-d", "1", "-i", mac_code])
        } else {
            self.status_message = format!("Unsupported OS: {}", os);
            return;
        };

        let result = Command::new(&tool).args(&args).status();

        match result {
            Ok(status) if status.success() => {
                self.status_message = format!("Switched to {}", name);
            }
            Ok(_) => {
                self.status_message = format!("Error switching to {} (Exit code non-zero)", name);
            }
            Err(e) => {
                self.status_message = format!("Failed to execute '{}': {}", tool, e);
            }
        }
    }
}

impl eframe::App for DisplaySwitcherApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if ctx.input(|i| i.key_pressed(egui::Key::Num0) || i.key_pressed(egui::Key::D)) {
            self.switch_input("DisplayPort", "0x0f", "15");
        }
        if ctx.input(|i| i.key_pressed(egui::Key::Num1)) {
            self.switch_input("HDMI 1", "0x11", "17");
        }
        if ctx.input(|i| i.key_pressed(egui::Key::Num2)) {
            self.switch_input("HDMI 2", "0x12", "18");
        }
        if ctx.input(|i| i.key_pressed(egui::Key::Num3)) {
            self.switch_input("HDMI 3", "0x13", "19");
        }
        if ctx.input(|i| i.key_pressed(egui::Key::Escape) || i.key_pressed(egui::Key::X)) {
            std::process::exit(0);
        }

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Monitor Input Switcher");
            ui.separator();

            ui.add_space(5.0);
            if ui.button("0 / D) DisplayPort - Mac Pro Workstation").clicked() {
                self.switch_input("DisplayPort", "0x0f", "15");
            }
            if ui.button("1) HDMI 1 - Mac Pro Ubuntu Server").clicked() {
                self.switch_input("HDMI 1", "0x11", "17");
            }
            if ui.button("2) HDMI 2 - Mac Pro Gaming PC").clicked() {
                self.switch_input("HDMI 2", "0x12", "18");
            }
            if ui.button("3) HDMI 3 - AUX").clicked() {
                self.switch_input("HDMI 3", "0x13", "19");
            }

            ui.add_space(10.0);
            ui.separator();
            ui.label(&self.status_message);

            ui.with_layout(egui::Layout::bottom_up(egui::Align::Center), |ui| {
                ui.label("Press X or Esc to exit");
            });
        });
    }
}

fn main() -> Result<(), eframe::Error> {
    let viewport_builder = egui::ViewportBuilder::default()
        .with_position([0.0, 0.0])
        .with_inner_size([340.0, 270.0])
        .with_resizable(false)
        .with_title("Display Switcher");

    let options = eframe::NativeOptions {
        viewport: viewport_builder,
        ..Default::default()
    };

    eframe::run_native(
        "Display Switcher",
        options,
        Box::new(|_| Ok(Box::new(DisplaySwitcherApp::default()))),
    )
}
EOF

RELEASE_BINARY="target/release/$APP_NAME"

echo "==> Building $APP_NAME locally in temp space..."
cargo build --release

if [[ ! -f "$RELEASE_BINARY" ]]; then
    echo "ERROR: Build failed. Binary not found at $RELEASE_BINARY." >&2
    exit 1
fi

if [[ "$OSTYPE" == "Linux" ]]; then
    INSTALL_DIR="/opt/display-switcher"
    TARGET_BIN="$INSTALL_DIR/$APP_NAME"
    DESKTOP_FILE="/usr/share/applications/display-switcher.desktop"

    echo "==> Deploying for Linux to $INSTALL_DIR..."
    
    if [[ $EUID -ne 0 ]]; then
        echo "Authentication required to install to $INSTALL_DIR..."
        sudo -v
    fi

    sudo mkdir -p "$INSTALL_DIR"
    sudo cp -f "$RELEASE_BINARY" "$TARGET_BIN"
    sudo chmod +x "$TARGET_BIN"

    if [[ ! -e "/usr/local/bin/$APP_NAME" ]]; then
        echo "==> Creating symlink in /usr/local/bin..."
        sudo ln -sf "$TARGET_BIN" "/usr/local/bin/$APP_NAME"
    fi

    echo "==> Generating system-wide .desktop launcher..."
    sudo tee "$DESKTOP_FILE" > /dev/null << EOF
[Desktop Entry]
Name=Display Switcher
Comment=Switch monitor inputs via DDC/CI
Exec=/usr/local/bin/display-switcher
Icon=preferences-desktop-display
Terminal=false
Type=Application
Categories=Utility;Settings;
EOF

    sudo update-desktop-database 2>/dev/null || true

    echo "==> Linux build and .desktop launcher installed successfully!"

elif [[ "$OSTYPE" == "Darwin" ]]; then
    APP_BUNDLE="/Applications/Display-Switcher.app"
    CONTENTS_DIR="$APP_BUNDLE/Contents"
    MACOS_DIR="$CONTENTS_DIR/MacOS"
    RESOURCES_DIR="$CONTENTS_DIR/Resources"

    echo "==> Moving old macOS application bundle to Trash..."
    if [[ -d "$APP_BUNDLE" ]]; then
        mkdir -p "$HOME/.Trash"
        mv "$APP_BUNDLE" "$HOME/.Trash/Display-Switcher.app.$(date +%s)" || true
    fi

    echo "==> Deploying fresh macOS app bundle to $APP_BUNDLE..."

    mkdir -p "$MACOS_DIR"
    mkdir -p "$RESOURCES_DIR"

    cp "$RELEASE_BINARY" "$MACOS_DIR/$APP_NAME"
    chmod +x "$MACOS_DIR/$APP_NAME"

    cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>display-switcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.display-switcher</string>
    <key>CFBundleName</key>
    <string>Display-Switcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

    xattr -rd com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

    echo "==> macOS application bundle successfully created at $APP_BUNDLE!"

else
    echo "ERROR: Unsupported operating system: [$OSTYPE]" >&2
    exit 1
fi

echo "==> Done! Full output logged to: $LOG_FILE"
open "$LOG_FILE" 2>/dev/null || xdg-open "$LOG_FILE" 2>/dev/null || true
# <LAST_SAVED> 20260927 19:02:32
