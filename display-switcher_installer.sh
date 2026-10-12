#!/usr/bin/env bash
# -*- mode: shell-script -*-
# Self-contained build and deployment script for universal display-switcher

OSTYPE=$(uname -s)
ARCH=$(uname -m | tr '[:lower:]' '[:upper:]')
[[ "$OSTYPE" == *"MINGW"* || "$OSTYPE" == *"MSYS"* || "$OSTYPE" == *"CYGWIN"* || "$OSTYPE" == *"NT"* ]] && OSTYPE="Win"

[[ -z $RED ]] && source .ansi 2>/dev/null || true
[[ -z "$(which mytools)" ]] && echo "ERROR: mytools not found. Must be installed." && exit 1

LOG_FILE="$HOME/Desktop/display-switcher_install.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "==> Universal Display-Switcher Installation Started: $(date)"
echo "=================================================="

# ==========================================
# PRE-FLIGHT CHECK PHASE: Validate all dependencies upfront (No Auto-Install)
# ==========================================
echo "==> Performing comprehensive pre-flight checks..."

MISSING_TOOLS=()

# 1. Check Display Control Tool
if [[ "$OSTYPE" == "Linux" ]]; then
    REQUIRED_TOOL="ddcutil"
    RESOLVED_TOOL=$(sh -c 'export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; which ddcutil' 2>/dev/null || true)
elif [[ "$OSTYPE" == "Darwin" ]]; then
    REQUIRED_TOOL="ddcctl"
    RESOLVED_TOOL=$(sh -c 'export PATH="/opt/local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; which ddcctl' 2>/dev/null || true)
else
    REQUIRED_TOOL="ControlMyMonitor.exe"
    RESOLVED_TOOL=$(which "$REQUIRED_TOOL" 2>/dev/null || true)
fi

if [[ -z "$RESOLVED_TOOL" ]]; then
    MISSING_TOOLS+=("$REQUIRED_TOOL (Display control utility)")
else
    echo "==> Found required tool [$REQUIRED_TOOL] at: $RESOLVED_TOOL"
fi

# 2. Check Rust / Cargo
RESOLVED_CARGO=$(sh -c 'export PATH="/opt/local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.cargo/bin:$PATH"; which cargo' 2>/dev/null || true)
if [[ -z "$RESOLVED_CARGO" ]]; then
    MISSING_TOOLS+=("cargo / rustc (Rust toolchain)")
else
    echo "==> Found required tool [cargo] at: $RESOLVED_CARGO"
fi

# 3. Check Platform Build Essentials / Compilers
if [[ "$OSTYPE" == "Darwin" ]]; then
    if ! xcode-select -p &>/dev/null; then
        MISSING_TOOLS+=("Xcode Command Line Tools")
    else
        echo "==> Found required tool [Xcode CLT] at: $(xcode-select -p)"
    fi
elif [[ "$OSTYPE" == "Linux" ]]; then
    if ! command -v cc &>/dev/null && ! command -v gcc &>/dev/null; then
        MISSING_TOOLS+=("build-essential / gcc (C compiler)")
    else
        echo "==> Found required build compiler."
    fi
fi

# Abort if any required tools are missing, listing all of them at once
if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    echo ""
    echo "=================================================="
    echo "ERROR: Pre-flight check failed! The following required tool(s) are missing:"
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "  - $tool"
    done
    echo ""
    echo "Please run your environment pre-flight / bootstrap installer"
    echo "to set up these missing dependencies before running this app installer."
    echo "=================================================="
    exit 1
fi

set -euo pipefail

APP_NAME="display-switcher"

echo "==> Performing safe termination of running $APP_NAME instances..."
CURRENT_PID=$$
for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || pgrep -f "/$APP_NAME\$" 2>/dev/null || true); do
    if [[ "$pid" != "$CURRENT_PID" ]]; then
        echo "--> Stopping running instance with PID: $pid"
        kill -15 "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
done

echo "==> Creating secure local temp build directory..."
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

cd "$BUILD_DIR"

echo "==> Generating Cargo.toml..."
cat << 'EOF' > Cargo.toml
[package]
name = "display-switcher"
version = "2.1.0"
edition = "2021"

[dependencies]
eframe = "0.29"
egui = "0.29"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
directories = "5.0"
fs4 = "0.7"
EOF

echo "==> Generating cross-platform Rust source files..."
mkdir -p src
cat << 'EOF' > src/main.rs
use eframe::egui;
use serde::{Deserialize, Serialize};
use std::fs::{self, File};
use std::path::PathBuf;
use std::process::Command;
use directories::ProjectDirs;
use fs4::FileExt;

#[derive(Clone, Copy, PartialEq, Debug, Serialize, Deserialize)]
enum InputType {
    Hdmi,
    DisplayPort,
}

#[derive(Clone, Serialize, Deserialize)]
struct DisplayInput {
    name: String,
    linux_code: String,
    mac_code: String,
    win_code: String,
    input_type: InputType,
}

#[derive(Serialize, Deserialize)]
struct Prefs {
    inputs: Vec<DisplayInput>,
    window_pos: Option<[f32; 2]>,
}

struct DisplaySwitcherApp {
    status_message: String,
    inputs: Vec<DisplayInput>,
    hdmi_indices: Vec<usize>,
    dp_indices: Vec<usize>,
    current_hdmi_cursor: usize,
    current_dp_cursor: usize,
    editing_index: Option<usize>,
    edit_buffer: String,
    _lock_file: Option<File>,
    pid_path: PathBuf,
    window_pos: Option<[f32; 2]>,
}

impl DisplaySwitcherApp {
    fn get_prefs_path() -> Option<PathBuf> {
        if let Some(proj_dirs) = ProjectDirs::from("com", "local", "display-switcher") {
            let dir = proj_dirs.config_dir();
            let _ = fs::create_dir_all(dir);
            Some(dir.join("preferences.json"))
        } else {
            None
        }
    }

    fn default_inputs() -> Vec<DisplayInput> {
        let mut discovered = Vec::new();
        discovered.push(DisplayInput {
            name: "DisplayPort".into(),
            linux_code: "0x0f".to_string(),
            mac_code: "15".to_string(),
            win_code: "15".to_string(),
            input_type: InputType::DisplayPort,
        });
        discovered.push(DisplayInput {
            name: "HDMI 1".into(),
            linux_code: "0x11".to_string(),
            mac_code: "17".to_string(),
            win_code: "17".to_string(),
            input_type: InputType::Hdmi,
        });
        discovered.push(DisplayInput {
            name: "HDMI 2".into(),
            linux_code: "0x12".to_string(),
            mac_code: "18".to_string(),
            win_code: "18".to_string(),
            input_type: InputType::Hdmi,
        });
        discovered.push(DisplayInput {
            name: "HDMI 3".into(),
            linux_code: "0x13".to_string(),
            mac_code: "19".to_string(),
            win_code: "19".to_string(),
            input_type: InputType::Hdmi,
        });
        discovered
    }

    fn load_prefs() -> (Vec<DisplayInput>, Option<[f32; 2]>) {
        if let Some(path) = Self::get_prefs_path() {
            if path.exists() {
                if let Ok(data) = fs::read_to_string(&path) {
                    if let Ok(prefs) = serde_json::from_str::<Prefs>(&data) {
                        let inputs = if prefs.inputs.is_empty() {
                            Self::default_inputs()
                        } else {
                            prefs.inputs
                        };
                        return (inputs, prefs.window_pos);
                    }
                }
            }
        }
        (Self::default_inputs(), None)
    }

    fn save_prefs(&self) {
        let pos = if std::env::consts::OS == "linux" { None } else { self.window_pos };
        if let Some(path) = Self::get_prefs_path() {
            let prefs = Prefs { 
                inputs: self.inputs.clone(),
                window_pos: pos,
            };
            if let Ok(data) = serde_json::to_string_pretty(&prefs) {
                let _ = fs::write(path, data);
            }
        }
    }

    fn switch_input(&mut self, name: &str, linux_code: &str, mac_code: &str, win_code: &str) {
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
        } else if os == "windows" {
            ("ControlMyMonitor.exe".to_string(), vec!["/SetValue", "Primary", "60", win_code])
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
                self.status_message = format!("Error switching to {} (Non-zero exit)", name);
            }
            Err(e) => {
                self.status_message = format!("Failed to execute '{}': {}", tool, e);
            }
        }
    }

    fn trigger_input_by_index(&mut self, index: usize) {
        if index < self.inputs.len() {
            let target = self.inputs[index].clone();
            self.switch_input(&target.name, &target.linux_code, &target.mac_code, &target.win_code);
        }
    }

    fn cycle_hdmi(&mut self) {
        if self.hdmi_indices.is_empty() {
            self.status_message = "No HDMI inputs available to cycle.".into();
            return;
        }
        let target_idx = self.hdmi_indices[self.current_hdmi_cursor];
        let target = self.inputs[target_idx].clone();
        
        self.switch_input(&target.name, &target.linux_code, &target.mac_code, &target.win_code);
        self.current_hdmi_cursor = (self.current_hdmi_cursor + 1) % self.hdmi_indices.len();
    }

    fn cycle_dp(&mut self) {
        if self.dp_indices.is_empty() {
            self.status_message = "No DisplayPort inputs available to cycle.".into();
            return;
        }
        let target_idx = self.dp_indices[self.current_dp_cursor];
        let target = self.inputs[target_idx].clone();
        
        self.switch_input(&target.name, &target.linux_code, &target.mac_code, &target.win_code);
        self.current_dp_cursor = (self.current_dp_cursor + 1) % self.dp_indices.len();
    }
}

impl eframe::App for DisplaySwitcherApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if let Some(rect) = ctx.input(|i| i.viewport().outer_rect) {
            self.window_pos = Some([rect.min.x, rect.min.y]);
        }

        let number_keys = [
            egui::Key::Num1, egui::Key::Num2, egui::Key::Num3,
            egui::Key::Num4, egui::Key::Num5, egui::Key::Num6,
            egui::Key::Num7, egui::Key::Num8, egui::Key::Num9,
        ];

        for (i, &key) in number_keys.iter().enumerate() {
            if ctx.input(|i| i.key_pressed(key)) {
                self.trigger_input_by_index(i);
            }
        }

        if ctx.input(|i| i.key_pressed(egui::Key::H)) {
            self.cycle_hdmi();
        }
        if ctx.input(|i| i.key_pressed(egui::Key::D)) {
            self.cycle_dp();
        }

        if ctx.input(|i| i.key_pressed(egui::Key::Escape) || i.key_pressed(egui::Key::X)) {
            self.save_prefs();
            let _ = fs::remove_file(&self.pid_path);
            std::process::exit(0);
        }

        let mut clicked_index: Option<usize> = None;
        let mut right_clicked_index: Option<usize> = None;
        let mut new_name_to_save: Option<(usize, String)> = None;

        let inputs_len = self.inputs.len();
        let editing_index = self.editing_index;

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Universal Display Switcher");
            ui.separator();
            ui.add_space(5.0);

            for index in 0..inputs_len {
                let input_name = self.inputs[index].name.clone();
                let label_text = format!("{}) {}", index + 1, input_name);

                if let Some(edit_idx) = editing_index {
                    if edit_idx == index {
                        ui.horizontal(|ui| {
                            ui.label(format!("{}) ", index + 1));
                            let response = ui.text_edit_singleline(&mut self.edit_buffer);
                            if response.lost_focus() && ctx.input(|i| i.key_pressed(egui::Key::Enter)) {
                                new_name_to_save = Some((index, self.edit_buffer.clone()));
                            }
                        });
                        continue;
                    }
                }

                let response = ui.button(label_text);
                if response.clicked() {
                    clicked_index = Some(index);
                }
                if response.secondary_clicked() {
                    right_clicked_index = Some(index);
                }
            }

            if let Some(r_idx) = right_clicked_index {
                self.editing_index = Some(r_idx);
                self.edit_buffer = self.inputs[r_idx].name.clone();
                self.status_message = format!("Renaming input {}. Press Enter when done.", r_idx + 1);
            }

            ui.add_space(10.0);
            ui.separator();
            ui.label(&self.status_message);

            ui.with_layout(egui::Layout::bottom_up(egui::Align::Center), |ui| {
                ui.label("Right-click button to rename | H/D cycle | 1-X switch");
            });
        });

        if let Some((idx, new_name)) = new_name_to_save {
            self.inputs[idx].name = new_name;
            self.save_prefs();
            self.editing_index = None;
            self.status_message = format!("Renamed input {} to '{}'", idx + 1, self.inputs[idx].name);
        }

        if let Some(index) = clicked_index {
            self.trigger_input_by_index(index);
        }
    }
}

fn main() -> Result<(), eframe::Error> {
    let proj_dirs = ProjectDirs::from("com", "local", "display-switcher");
    let (lock_path, pid_path) = if let Some(ref dirs) = proj_dirs {
        let dir = dirs.config_dir();
        let _ = fs::create_dir_all(dir);
        (dir.join("app.lock"), dir.join("app.pid"))
    } else {
        (PathBuf::from("display-switcher.lock"), PathBuf::from("app.pid"))
    };

    let lock_file = File::create(&lock_path).expect("Failed to create lock file");
    
    if lock_file.try_lock_exclusive().is_err() {
        if std::env::consts::OS == "linux" || std::env::consts::OS == "macos" {
            if let Ok(pid_str) = fs::read_to_string(&pid_path) {
                if let Ok(old_pid) = pid_str.trim().parse::<u32>() {
                    let _ = Command::new("kill").args(["-15", &old_pid.to_string()]).status();
                    std::thread::sleep(std::time::Duration::from_millis(50));
                    let _ = Command::new("kill").args(["-9", &old_pid.to_string()]).status();
                }
            }
            let _ = fs::remove_file(&pid_path);
            std::thread::sleep(std::time::Duration::from_millis(100));
            let _ = lock_file.try_lock_exclusive();
        } else {
            std::process::exit(0);
        }
    }

    let current_pid = std::process::id();
    let _ = fs::write(&pid_path, current_pid.to_string());

    let pid_path_clone = pid_path.clone();
    std::panic::set_hook(Box::new(move |_| {
        let _ = fs::remove_file(&pid_path_clone);
    }));

    let (inputs, window_pos) = DisplaySwitcherApp::load_prefs();

    let mut hdmi_indices = Vec::new();
    let mut dp_indices = Vec::new();
    
    for (i, inp) in inputs.iter().enumerate() {
        match inp.input_type {
            InputType::Hdmi => hdmi_indices.push(i),
            InputType::DisplayPort => dp_indices.push(i),
        }
    }

    let app = DisplaySwitcherApp {
        status_message: format!("Loaded {} input(s). Ready.", inputs.len()),
        inputs,
        hdmi_indices,
        dp_indices,
        current_hdmi_cursor: 0,
        current_dp_cursor: 0,
        editing_index: None,
        edit_buffer: String::new(),
        _lock_file: Some(lock_file),
        pid_path: pid_path.clone(),
        window_pos,
    };

    let mut viewport_builder = egui::ViewportBuilder::default()
        .with_inner_size([340.0, 310.0])
        .with_resizable(false)
        .with_title("Universal Display Switcher");

    if let Some(pos) = window_pos {
        viewport_builder = viewport_builder.with_position([pos[0], pos[1]]);
    }

    let options = eframe::NativeOptions {
        viewport: viewport_builder,
        ..Default::default()
    };

    let res = eframe::run_native(
        "Universal Display Switcher",
        options,
        Box::new(move |_| Ok(Box::new(app))),
    );

    let _ = fs::remove_file(&pid_path);
    res
}
EOF

RELEASE_BINARY="target/release/$APP_NAME"
if [[ "$OSTYPE" == "Win" ]]; then
    RELEASE_BINARY="target/release/$APP_NAME.exe"
fi

echo "==> Building $APP_NAME locally..."
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
        sudo -v
    fi

    sudo mkdir -p "$INSTALL_DIR"
    sudo cp -f "$RELEASE_BINARY" "$TARGET_BIN"
    sudo chmod +x "$TARGET_BIN"

    if [[ ! -e "/usr/local/bin/$APP_NAME" ]]; then
        sudo ln -sf "$TARGET_BIN" "/usr/local/bin/$APP_NAME"
    fi

    sudo tee "$DESKTOP_FILE" > /dev/null << EOF
[Desktop Entry]
Name=Universal Display Switcher
Comment=Switch monitor inputs via DDC/CI dynamically
Exec=/usr/local/bin/display-switcher
Icon=preferences-desktop-display
Terminal=false
Type=Application
Categories=Utility;Settings;
EOF

    sudo update-desktop-database 2>/dev/null || true
    echo "==> Linux deployment finished successfully!"

elif [[ "$OSTYPE" == "Darwin" ]]; then
    APP_BUNDLE="/Applications/Display-Switcher.app"
    
    echo "==> Fully removing old application bundle from /Applications..."
    rm -rf "$APP_BUNDLE"

    CONTENTS_DIR="$APP_BUNDLE/Contents"
    MACOS_DIR="$CONTENTS_DIR/MacOS"
    RESOURCES_DIR="$CONTENTS_DIR/Resources"

    echo "==> Deploying fresh macOS application bundle to $APP_BUNDLE..."
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

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
    <string>2.1</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

    codesign --force --deep --sign - "$APP_BUNDLE"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"
    touch "$APP_BUNDLE"
    echo "==> macOS application bundle created and registered successfully!"

elif [[ "$OSTYPE" == "Win" ]]; then
    echo "==> Deploying for Windows to LocalAppData Programs..."
    
    powershell.exe -Command "
        \$dir = [Environment]::GetFolderPath('LocalApplicationData') + '\\Programs\\Display Switcher';
        New-Item -ItemType Directory -Force -Path \$dir | Out-Null;
        Copy-Item -Force '$RELEASE_BINARY' (Join-Path \$dir 'display-switcher.exe');
        
        \$startMenu = [Environment]::GetFolderPath('StartMenu') + '\\Programs';
        \$ws = New-Object -ComObject WScript.Shell;
        \$sc = \$ws.CreateShortcut((Join-Path \$startMenu 'Display Switcher.lnk'));
        \$sc.TargetPath = (Join-Path \$dir 'display-switcher.exe');
        \$sc.WorkingDirectory = \$dir;
        \$sc.Save();
    "
    echo "==> Windows installation and Start Menu shortcut creation completed successfully!"
fi

echo "==> Done! Full output logged to: $LOG_FILE"
# <LAST_SAVED> 20261011 22:24:40
