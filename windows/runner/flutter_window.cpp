#include "flutter_window.h"

#include <dwmapi.h>
#include <windowsx.h>

#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <optional>
#include <map>
#include <string>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // platform channel for titlebar color
  auto messenger = flutter_controller_->engine()->messenger();
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger,
      "win_titlebar_color",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [hwnd = GetHandle()](const flutter::MethodCall<flutter::EncodableValue>& call,
                           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setTitleBarColor") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Error("INVALID_ARGUMENTS", "Expected map with RGB values");
            return;
          }

          int r = std::get<int>(args->at(flutter::EncodableValue("r")));
          int g = std::get<int>(args->at(flutter::EncodableValue("g")));
          int b = std::get<int>(args->at(flutter::EncodableValue("b")));
          COLORREF color = RGB(r, g, b);

          // 35 is DWMWA_CAPTION_COLOR in recent Windows 10+ SDKs
          HRESULT hr = DwmSetWindowAttribute(hwnd, 35, &color, sizeof(color));
          if (SUCCEEDED(hr)) {
            result->Success();
          } else {
            result->Error("DWM_ERROR", "Failed to set title bar color");
          }
        } else {
          result->NotImplemented();
        }
      });

  method_channel_ = std::move(channel);

  // platform channel for capturing media keys (play/pause/next/previous)
  media_keys_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger,
      "harmony/media_keys",
      &flutter::StandardMethodCodec::GetInstance());
  media_keys_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "enable") {
          result->Success(flutter::EncodableValue(this->RegisterMediaKeys()));
        } else if (call.method_name() == "disable") {
          this->UnregisterMediaKeys();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  // Catch media commands that arrive as WM_APPCOMMAND (not as key presses):
  // register to see them system-wide through the shell hook.
  shell_hook_message_ = ::RegisterWindowMessageW(L"SHELLHOOK");
  ::RegisterShellHookWindow(GetHandle());

  return true;
}

namespace {
// Maps a WM_APPCOMMAND media command to the name sent to Dart (or nullptr).
const char* MediaKeyForAppCommand(int cmd) {
  switch (cmd) {
    case APPCOMMAND_MEDIA_PLAY_PAUSE: return "playPause";
    case APPCOMMAND_MEDIA_PLAY: return "play";
    case APPCOMMAND_MEDIA_PAUSE: return "pause";
    case APPCOMMAND_MEDIA_NEXTTRACK: return "next";
    case APPCOMMAND_MEDIA_PREVIOUSTRACK: return "previous";
    case APPCOMMAND_MEDIA_STOP: return "stop";
    default: return nullptr;
  }
}
}  // namespace

void FlutterWindow::ForwardMediaKey(const char* key) {
  if (media_keys_channel_ && key) {
    media_keys_channel_->InvokeMethod(
        "onKey", std::make_unique<flutter::EncodableValue>(std::string(key)));
  }
}

namespace {
constexpr int kHotkeyPlayPause = 0x4801;
constexpr int kHotkeyNext = 0x4802;
constexpr int kHotkeyPrevious = 0x4803;
constexpr int kHotkeyStop = 0x4804;
}  // namespace

// Returns true if all media keys are now owned by Harmony.
bool FlutterWindow::RegisterMediaKeys() {
  if (media_keys_registered_) return true;
  HWND hwnd = GetHandle();
  if (!hwnd) return false;
  const UINT mods = MOD_NOREPEAT;
  bool ok = true;
  ok &= ::RegisterHotKey(hwnd, kHotkeyPlayPause, mods, VK_MEDIA_PLAY_PAUSE) != 0;
  ok &= ::RegisterHotKey(hwnd, kHotkeyNext, mods, VK_MEDIA_NEXT_TRACK) != 0;
  ok &= ::RegisterHotKey(hwnd, kHotkeyPrevious, mods, VK_MEDIA_PREV_TRACK) != 0;
  ok &= ::RegisterHotKey(hwnd, kHotkeyStop, mods, VK_MEDIA_STOP) != 0;
  media_keys_registered_ = true;  // so Unregister cleans up partial success
  return ok;
}

void FlutterWindow::UnregisterMediaKeys() {
  if (!media_keys_registered_) return;
  HWND hwnd = GetHandle();
  if (hwnd) {
    ::UnregisterHotKey(hwnd, kHotkeyPlayPause);
    ::UnregisterHotKey(hwnd, kHotkeyNext);
    ::UnregisterHotKey(hwnd, kHotkeyPrevious);
    ::UnregisterHotKey(hwnd, kHotkeyStop);
  }
  media_keys_registered_ = false;
}

void FlutterWindow::OnDestroy() {
  if (GetHandle()) ::DeregisterShellHookWindow(GetHandle());
  UnregisterMediaKeys();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Headset button delivered as an app command to ANY window (shell hook)
  if (shell_hook_message_ != 0 && message == shell_hook_message_ &&
      wparam == HSHELL_APPCOMMAND && media_keys_registered_) {
    const char* key = MediaKeyForAppCommand(GET_APPCOMMAND_LPARAM(lparam));
    if (key) {
      ForwardMediaKey(key);
      return 0;
    }
  }
  // ...or delivered directly to this window while it is in front
  if (message == WM_APPCOMMAND && media_keys_registered_) {
    const char* key = MediaKeyForAppCommand(GET_APPCOMMAND_LPARAM(lparam));
    if (key) {
      ForwardMediaKey(key);
      return TRUE;
    }
  }

  if (message == WM_HOTKEY && media_keys_channel_) {
    const char* key = nullptr;
    switch (static_cast<int>(wparam)) {
      case kHotkeyPlayPause: key = "playPause"; break;
      case kHotkeyNext: key = "next"; break;
      case kHotkeyPrevious: key = "previous"; break;
      case kHotkeyStop: key = "stop"; break;
    }
    if (key) {
      media_keys_channel_->InvokeMethod(
          "onKey", std::make_unique<flutter::EncodableValue>(std::string(key)));
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
