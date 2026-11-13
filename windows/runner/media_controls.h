#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <windows.h>

#include <memory>
#include <string>

// Posted to the window when a media button is pressed (from Windows'
// media overlay, the keyboard's media keys, or the taskbar thumbnail
// buttons); wparam is a MediaButton.
constexpr UINT kMediaButtonMessage = WM_APP + 0x4D;

enum class MediaButton : int { kPlay = 1, kPause, kNext, kPrevious, kStop };

// Windows' System Media Transport Controls (the media overlay shown for
// the volume / media keys, which also deliver those keys while the app is
// in the background) and the taskbar thumbnail's play / previous / next
// buttons, driven from Dart over the "jellyfin_client/media_controls"
// channel.
class MediaControls {
 public:
  MediaControls(HWND window, flutter::BinaryMessenger* messenger);
  ~MediaControls();

  // Call from the window procedure; true when it was ours.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Update(const flutter::EncodableMap& args);
  void Clear();
  void UpdateThumbButtons(bool show);
  void SendButton(MediaButton button);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // C++/WinRT objects live in the .cpp (pimpl) so this header stays plain.
  struct Smtc;
  std::unique_ptr<Smtc> smtc_;

  ITaskbarList3* taskbar_ = nullptr;
  UINT taskbar_created_message_ = 0;
  bool thumb_buttons_added_ = false;
  bool playing_ = false;
  bool can_next_ = false;
  bool can_previous_ = false;
  bool active_ = false;
  HICON icon_play_ = nullptr;
  HICON icon_pause_ = nullptr;
  HICON icon_next_ = nullptr;
  HICON icon_previous_ = nullptr;
};

#endif  // RUNNER_MEDIA_CONTROLS_H_
