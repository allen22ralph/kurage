#include "media_controls.h"

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <optional>

namespace {

using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;

// Thumbnail toolbar button ids (WM_COMMAND).
constexpr UINT kThumbPrevious = 0x4D01;
constexpr UINT kThumbPlayPause = 0x4D02;
constexpr UINT kThumbNext = 0x4D03;

std::optional<std::string> GetString(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return std::nullopt;
  if (auto* s = std::get_if<std::string>(&it->second)) return *s;
  return std::nullopt;
}

bool GetBool(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return false;
  if (auto* b = std::get_if<bool>(&it->second)) return *b;
  return false;
}

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

// A white glyph from Windows' icon font as an icon, for the thumbnail
// toolbar (16 px logical, drawn at the window's DPI).
HICON GlyphIcon(wchar_t glyph, UINT dpi) {
  const int size = MulDiv(16, dpi, 96);
  BITMAPV5HEADER bi = {};
  bi.bV5Size = sizeof(bi);
  bi.bV5Width = size;
  bi.bV5Height = -size;
  bi.bV5Planes = 1;
  bi.bV5BitCount = 32;
  bi.bV5Compression = BI_BITFIELDS;
  bi.bV5RedMask = 0x00FF0000;
  bi.bV5GreenMask = 0x0000FF00;
  bi.bV5BlueMask = 0x000000FF;
  bi.bV5AlphaMask = 0xFF000000;
  HDC screen = GetDC(nullptr);
  void* bits = nullptr;
  HBITMAP color = CreateDIBSection(screen, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
  HDC dc = CreateCompatibleDC(screen);
  HGDIOBJ old = SelectObject(dc, color);
  ZeroMemory(bits, size * size * 4);
  HFONT font = CreateFontW(-MulDiv(12, dpi, 96), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH,
                           L"Segoe MDL2 Assets");
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  RECT rect = {0, 0, size, size};
  wchar_t text[2] = {glyph, 0};
  DrawTextW(dc, text, 1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  GdiFlush();
  // GDI leaves alpha at 0: use the drawn brightness as alpha.
  auto* px = static_cast<uint32_t*>(bits);
  for (int i = 0; i < size * size; i++) {
    const uint32_t a = px[i] & 0xFF;
    px[i] = (a << 24) | (a << 16) | (a << 8) | a;
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
  SelectObject(dc, old);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO info = {TRUE, 0, 0, mask, color};
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(mask);
  DeleteObject(color);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
  return icon;
}

}  // namespace

struct MediaControls::Smtc {
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token token{};
};

MediaControls::MediaControls(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), smtc_(std::make_unique<Smtc>()) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "jellyfin_client/media_controls", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { HandleMethodCall(call, std::move(result)); });

  try {
    auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(window_, winrt::guid_of<SystemMediaTransportControls>(),
                                               winrt::put_abi(smtc_->controls)));
    smtc_->controls.IsPlayEnabled(true);
    smtc_->controls.IsPauseEnabled(true);
    smtc_->controls.IsStopEnabled(true);
    // Pressed on a worker thread: hand over to the window's thread, where
    // the channel may be used.
    HWND hwnd = window_;
    smtc_->token = smtc_->controls.ButtonPressed(
        [hwnd](const SystemMediaTransportControls&, const SystemMediaTransportControlsButtonPressedEventArgs& args) {
          MediaButton button;
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play: button = MediaButton::kPlay; break;
            case SystemMediaTransportControlsButton::Pause: button = MediaButton::kPause; break;
            case SystemMediaTransportControlsButton::Next: button = MediaButton::kNext; break;
            case SystemMediaTransportControlsButton::Previous: button = MediaButton::kPrevious; break;
            case SystemMediaTransportControlsButton::Stop: button = MediaButton::kStop; break;
            default: return;
          }
          PostMessage(hwnd, kMediaButtonMessage, static_cast<WPARAM>(button), 0);
        });
  } catch (const winrt::hresult_error&) {
    smtc_->controls = nullptr;  // e.g. Windows N without media features
  }

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarButtonCreated");
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar_)))) {
    taskbar_ = nullptr;
  } else if (FAILED(taskbar_->HrInit())) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
  const UINT dpi = GetDpiForWindow(window_);
  icon_play_ = GlyphIcon(static_cast<wchar_t>(0xE768), dpi);
  icon_pause_ = GlyphIcon(static_cast<wchar_t>(0xE769), dpi);
  icon_next_ = GlyphIcon(static_cast<wchar_t>(0xE893), dpi);
  icon_previous_ = GlyphIcon(static_cast<wchar_t>(0xE892), dpi);
}

MediaControls::~MediaControls() {
  if (smtc_->controls) {
    try {
      smtc_->controls.ButtonPressed(smtc_->token);
      smtc_->controls.IsEnabled(false);
    } catch (...) {
    }
  }
  if (taskbar_) taskbar_->Release();
  for (HICON icon : {icon_play_, icon_pause_, icon_next_, icon_previous_}) {
    if (icon) DestroyIcon(icon);
  }
}

bool MediaControls::HandleMessage(UINT message, WPARAM wparam, LPARAM) {
  if (message == kMediaButtonMessage) {
    SendButton(static_cast<MediaButton>(wparam));
    return true;
  }
  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    switch (LOWORD(wparam)) {
      case kThumbPlayPause: SendButton(playing_ ? MediaButton::kPause : MediaButton::kPlay); return true;
      case kThumbNext: SendButton(MediaButton::kNext); return true;
      case kThumbPrevious: SendButton(MediaButton::kPrevious); return true;
    }
  }
  if (message == taskbar_created_message_ && taskbar_created_message_ != 0) {
    // Explorer restarted: the buttons have to be added again.
    thumb_buttons_added_ = false;
    if (active_) UpdateThumbButtons(true);
  }
  return false;
}

void MediaControls::SendButton(MediaButton button) {
  const char* name = "play";
  switch (button) {
    case MediaButton::kPlay: name = "play"; break;
    case MediaButton::kPause: name = "pause"; break;
    case MediaButton::kNext: name = "next"; break;
    case MediaButton::kPrevious: name = "previous"; break;
    case MediaButton::kStop: name = "stop"; break;
  }
  channel_->InvokeMethod("button", std::make_unique<flutter::EncodableValue>(name));
}

void MediaControls::HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "update") {
    if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) Update(*args);
    result->Success();
  } else if (call.method_name() == "clear") {
    Clear();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void MediaControls::Update(const flutter::EncodableMap& args) {
  playing_ = GetBool(args, "playing");
  can_next_ = GetBool(args, "canNext");
  can_previous_ = GetBool(args, "canPrevious");
  active_ = true;
  if (smtc_->controls) {
    try {
      auto& c = smtc_->controls;
      c.IsEnabled(true);
      c.IsNextEnabled(can_next_);
      c.IsPreviousEnabled(can_previous_);
      c.PlaybackStatus(playing_ ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
      auto updater = c.DisplayUpdater();
      updater.Type(MediaPlaybackType::Video);
      updater.VideoProperties().Title(winrt::hstring(Widen(GetString(args, "title").value_or(""))));
      updater.VideoProperties().Subtitle(winrt::hstring(Widen(GetString(args, "subtitle").value_or(""))));
      if (auto thumb = GetString(args, "thumbnail"); thumb && !thumb->empty()) {
        updater.Thumbnail(winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(
            winrt::Windows::Foundation::Uri(winrt::hstring(Widen(*thumb)))));
      } else {
        updater.Thumbnail(nullptr);
      }
      updater.Update();
    } catch (const winrt::hresult_error&) {
    }
  }
  UpdateThumbButtons(true);
}

void MediaControls::Clear() {
  active_ = false;
  if (smtc_->controls) {
    try {
      smtc_->controls.PlaybackStatus(MediaPlaybackStatus::Closed);
      smtc_->controls.DisplayUpdater().ClearAll();
      smtc_->controls.IsEnabled(false);
    } catch (const winrt::hresult_error&) {
    }
  }
  UpdateThumbButtons(false);
}

void MediaControls::UpdateThumbButtons(bool show) {
  if (!taskbar_) return;
  THUMBBUTTON buttons[3] = {};
  const UINT ids[3] = {kThumbPrevious, kThumbPlayPause, kThumbNext};
  for (int i = 0; i < 3; i++) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    buttons[i].dwFlags = show ? THBF_ENABLED : THBF_HIDDEN;
  }
  buttons[0].hIcon = icon_previous_;
  wcscpy_s(buttons[0].szTip, L"Previous episode");
  if (!can_previous_ && show) buttons[0].dwFlags = THBF_DISABLED;
  buttons[1].hIcon = playing_ ? icon_pause_ : icon_play_;
  wcscpy_s(buttons[1].szTip, playing_ ? L"Pause" : L"Play");
  buttons[2].hIcon = icon_next_;
  wcscpy_s(buttons[2].szTip, L"Next episode");
  if (!can_next_ && show) buttons[2].dwFlags = THBF_DISABLED;
  if (!thumb_buttons_added_) {
    if (!show) return;  // nothing to hide yet
    thumb_buttons_added_ = SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 3, buttons));
  } else {
    taskbar_->ThumbBarUpdateButtons(window_, 3, buttons);
  }
}
