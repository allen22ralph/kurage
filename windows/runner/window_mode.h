#ifndef RUNNER_WINDOW_MODE_H_
#define RUNNER_WINDOW_MODE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Picture-in-picture for the player: a small, always-on-top window in the
// corner of the screen, and back. Over "jellyfin_client/window".
class WindowMode {
 public:
  WindowMode(HWND window, flutter::BinaryMessenger* messenger);

 private:
  void EnterMini(int width, int height);
  void ExitMini();

  // Fullscreen (media_kit's) misjudges a maximized window: restore it
  // first, and maximize it again after.
  void BeforeFullscreen();
  void AfterFullscreen();

  // Tells the window (and Flutter in it) its real size again.
  void Relayout();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool mini_ = false;
  bool maximized_before_fullscreen_ = false;
  WINDOWPLACEMENT saved_ = {sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_WINDOW_MODE_H_
