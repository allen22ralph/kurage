#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl_core.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kAppUserModelId[] = L"Kurage.App";
constexpr wchar_t kAppName[] = L"Kurage";

void SetRegistryString(HKEY key, const wchar_t* name, const std::wstring& value) {
  ::RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

// Gives the app a name and icon in Windows' media overlay, volume mixer and
// notifications. Without an installer, Windows only knows the app by the
// ID it sets for itself, so the ID's name and icon are registered for the
// current user (no admin rights needed) each start, following the exe if
// it moves.
void RegisterAppIdentity() {
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  wchar_t exe[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return;
  std::wstring folder(exe, length);
  folder = folder.substr(0, folder.find_last_of(L'\\'));
  HKEY key;
  const std::wstring path = std::wstring(L"Software\\Classes\\AppUserModelId\\") + kAppUserModelId;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  SetRegistryString(key, L"DisplayName", kAppName);
  SetRegistryString(key, L"IconUri", folder + L"\\data\\app_icon.ico");
  ::RegCloseKey(key);
}

// The media overlay names an unpackaged app only once a Start menu shortcut
// carries its ID: one for this exe ("Kurage"), made or pointed at
// it again if the app moved. Needs COM.
void EnsureStartMenuShortcut() {
  wchar_t exe[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (length == 0 || length == MAX_PATH) return;
  PWSTR programs = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs))) return;
  const std::wstring link = std::wstring(programs) + L"\\" + kAppName + L".lnk";
  // The app was called "Jellyfin Client" before: its old shortcut goes.
  ::DeleteFileW((std::wstring(programs) + L"\\Jellyfin Client.lnk").c_str());
  ::CoTaskMemFree(programs);

  IShellLinkW* shell_link = nullptr;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&shell_link)))) return;
  IPersistFile* file = nullptr;
  if (SUCCEEDED(shell_link->QueryInterface(IID_PPV_ARGS(&file)))) {
    // Already there, for this exe: nothing to do.
    wchar_t target[MAX_PATH] = L"";
    if (SUCCEEDED(file->Load(link.c_str(), STGM_READ)) &&
        SUCCEEDED(shell_link->GetPath(target, MAX_PATH, nullptr, 0)) && _wcsicmp(target, exe) == 0) {
      file->Release();
      shell_link->Release();
      return;
    }
    shell_link->SetPath(exe);
    shell_link->SetIconLocation(exe, 0);
    IPropertyStore* properties = nullptr;
    if (SUCCEEDED(shell_link->QueryInterface(IID_PPV_ARGS(&properties)))) {
      PROPVARIANT id;
      if (SUCCEEDED(::InitPropVariantFromString(kAppUserModelId, &id))) {
        properties->SetValue(PKEY_AppUserModel_ID, id);
        properties->Commit();
        ::PropVariantClear(&id);
      }
      properties->Release();
    }
    file->Save(link.c_str(), TRUE);
    file->Release();
  }
  shell_link->Release();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  RegisterAppIdentity();
  EnsureStartMenuShortcut();

  flutter::DartProject project(L"data");
  // Skia, not Impeller: on Windows, Impeller (over OpenGL) stalled for up
  // to 0.4s at a time while Depth's deck moved; Skia drew the same frames
  // in about 3ms.
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kAppName, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
