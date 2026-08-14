#include "my_application.h"

#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdlib>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr unsigned int kCapNetAdmin = 12;

bool HasNetAdminCapability() {
  std::ifstream status("/proc/self/status");
  std::string line;
  while (std::getline(status, line)) {
    if (line.rfind("CapEff:", 0) != 0) {
      continue;
    }
    std::istringstream value_stream(line.substr(7));
    unsigned long long capabilities = 0;
    value_stream >> std::hex >> capabilities;
    return (capabilities & (1ULL << kCapNetAdmin)) != 0;
  }
  return false;
}

std::string ExecutablePath(const char* fallback) {
  std::vector<char> buffer(4096);
  const ssize_t length =
      readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
  if (length <= 0) {
    return fallback == nullptr ? "vnt_app" : fallback;
  }
  buffer[static_cast<size_t>(length)] = '\0';
  return buffer.data();
}

std::string DirectoryName(const std::string& path) {
  const size_t separator = path.find_last_of('/');
  return separator == std::string::npos ? "." : path.substr(0, separator);
}

void AddEnvironment(std::vector<std::string>* arguments, const char* name) {
  const char* value = std::getenv(name);
  if (value != nullptr && value[0] != '\0') {
    arguments->emplace_back(std::string(name) + "=" + value);
  }
}

// Replaces the native runner with pkexec before GTK and the Flutter engine are
// created. pkexec/setpriv then exec the same runner with ambient network
// capabilities. This keeps flutter run attached to one process chain and
// avoids a temporary blank application window.
void RequestNetworkCapabilityBeforeFlutter(int argc, char** argv) {
  if (HasNetAdminCapability()) {
    return;
  }

  constexpr const char* kPkexec = "/usr/bin/pkexec";
  constexpr const char* kEnv = "/usr/bin/env";
  constexpr const char* kSetpriv = "/usr/bin/setpriv";
  if (access(kPkexec, X_OK) != 0 || access(kEnv, X_OK) != 0 ||
      access(kSetpriv, X_OK) != 0) {
    // Dart will show a detailed diagnostic if the system lacks these tools.
    return;
  }

  const std::string executable = ExecutablePath(argc > 0 ? argv[0] : nullptr);
  const std::string helper_path =
      DirectoryName(executable) + "/lib/vnt_app/linux_cap_helpers";
  const char* current_path = std::getenv("PATH");

  std::vector<std::string> arguments = {kPkexec, kEnv};
  for (const char* name : {"DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY",
                           "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
                           "HOME", "USER", "LOGNAME", "LANG", "LC_ALL"}) {
    AddEnvironment(&arguments, name);
  }
  arguments.emplace_back("PATH=" + helper_path + ":" +
                         (current_path == nullptr
                              ? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                              : current_path));
  arguments.emplace_back(kSetpriv);
  arguments.emplace_back("--reuid=" + std::to_string(getuid()));
  arguments.emplace_back("--regid=" + std::to_string(getgid()));
  arguments.emplace_back("--init-groups");
  arguments.emplace_back("--inh-caps=+net_admin,+net_raw");
  arguments.emplace_back("--ambient-caps=+net_admin,+net_raw");
  arguments.emplace_back(executable);
  for (int index = 1; index < argc; ++index) {
    arguments.emplace_back(argv[index]);
  }

  std::vector<char*> exec_arguments;
  exec_arguments.reserve(arguments.size() + 1);
  for (std::string& argument : arguments) {
    exec_arguments.push_back(&argument[0]);
  }
  exec_arguments.push_back(nullptr);

  std::fprintf(stderr,
               "[vnt permission] Requesting CAP_NET_ADMIN before Flutter "
               "engine startup.\n");
  std::fflush(stderr);
  execv(kPkexec, exec_arguments.data());
  perror("vnt_app: unable to start PolicyKit authorization");
}

}  // namespace

int main(int argc, char** argv) {
  RequestNetworkCapabilityBeforeFlutter(argc, argv);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
