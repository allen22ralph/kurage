#include "window_mode.h"

#include <flutter/standard_method_codec.h>

namespace {

int GetInt(const flutter::EncodableValue* args, const char* key, int fallback) {
  const auto* map = std::get_if<flutter::EncodableMap>(args);
  if (!map) return fallback;
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) return fallback;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  return fallback;
}

}  // namespace

WindowMode::WindowMode(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "jellyfin_client/window", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "enterMini") {
      EnterMini(GetInt(call.arguments(), "width", 480), GetInt(call.arguments(), "height", 270));
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "exitMini") {
      ExitMini();
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "beforeFullscreen") {
      BeforeFullscreen();
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "afterFullscreen") {
      AfterFullscreen();
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "relayout") {
      Relayout();
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "isMini") {
      result->Success(flutter::EncodableValue(mini_));
    } else {
      result->NotImplemented();
    }
  });
}

void WindowMode::EnterMini(int width, int height) {
  if (mini_) return;
  saved_.length = sizeof(WINDOWPLACEMENT);
  GetWindowPlacement(window_, &saved_);
  if (IsZoomed(window_)) ShowWindow(window_, SW_RESTORE);

  // Logical size -> pixels at the window's DPI, plus the frame.
  const UINT dpi = GetDpiForWindow(window_);
  RECT rect = {0, 0, MulDiv(width, dpi, 96), MulDiv(height, dpi, 96)};
  AdjustWindowRectExForDpi(&rect, static_cast<DWORD>(GetWindowLongPtr(window_, GWL_STYLE)), FALSE,
                           static_cast<DWORD>(GetWindowLongPtr(window_, GWL_EXSTYLE)), dpi);
  const int w = rect.right - rect.left;
  const int h = rect.bottom - rect.top;

  // Bottom-right of the screen the window is on, clear of the taskbar.
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor);
  const int margin = MulDiv(24, dpi, 96);
  const int x = monitor.rcWork.right - w - margin;
  const int y = monitor.rcWork.bottom - h - margin;
  SetWindowPos(window_, HWND_TOPMOST, x, y, w, h, SWP_SHOWWINDOW);
  mini_ = true;
}

void WindowMode::BeforeFullscreen() {
  maximized_before_fullscreen_ = IsZoomed(window_) != 0;
  if (maximized_before_fullscreen_) ShowWindow(window_, SW_RESTORE);
}

void WindowMode::AfterFullscreen() {
  if (maximized_before_fullscreen_) ShowWindow(window_, SW_MAXIMIZE);
  maximized_before_fullscreen_ = false;
  Relayout();
}

void WindowMode::Relayout() {
  RECT client;
  if (!GetClientRect(window_, &client)) return;
  SetWindowPos(window_, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  // The size message Flutter lays itself out by, with the real size.
  SendMessage(window_, WM_SIZE, IsZoomed(window_) ? SIZE_MAXIMIZED : SIZE_RESTORED,
              MAKELPARAM(client.right - client.left, client.bottom - client.top));
}

void WindowMode::ExitMini() {
  if (!mini_) return;
  mini_ = false;
  SetWindowPos(window_, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
  SetWindowPlacement(window_, &saved_);
  // Make Flutter (and the video) lay out again for the restored size.
  SetWindowPos(window_, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
}
