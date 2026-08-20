#include "my_application.h"

#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <pwd.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include <glib.h>

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

std::string LastError(const char* operation) {
  return std::string(operation) + ": " + std::strerror(errno);
}

void RedirectBootstrapLog() {
  const char* home = std::getenv("HOME");
  if (home == nullptr || home[0] == '\0') {
    return;
  }
  const std::string directory =
      std::string(home) + "/.local/share/top.daylight.vnt.www/logs";
  if (g_mkdir_with_parents(directory.c_str(), 0700) != 0) {
    return;
  }
  const std::string path = directory + "/linux-bootstrap.log";
  const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0600);
  if (fd < 0) {
    return;
  }
  dup2(fd, STDERR_FILENO);
  close(fd);
}

bool SetNetworkCapabilities(std::string* error) {
  __user_cap_header_struct header = {};
  __user_cap_data_struct data[2] = {};
  header.version = _LINUX_CAPABILITY_VERSION_3;
  header.pid = 0;
  const uint32_t mask = (1U << CAP_NET_ADMIN) | (1U << CAP_NET_RAW);
  data[0].effective = mask;
  data[0].permitted = mask;
  data[0].inheritable = mask;
  if (syscall(SYS_capset, &header, data) != 0) {
    *error = LastError("capset(CAP_NET_ADMIN,CAP_NET_RAW)");
    return false;
  }
  for (const int capability : {CAP_NET_ADMIN, CAP_NET_RAW}) {
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, capability, 0, 0) != 0) {
      *error = LastError("PR_CAP_AMBIENT_RAISE");
      return false;
    }
  }
  return true;
}

bool ParseUid(const char* value, uid_t* uid) {
  if (value == nullptr || value[0] == '\0' || value[0] == '-') {
    return false;
  }
  errno = 0;
  char* end = nullptr;
  const unsigned long parsed = std::strtoul(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed > UINT_MAX) {
    return false;
  }
  *uid = static_cast<uid_t>(parsed);
  return static_cast<unsigned long>(*uid) == parsed;
}

// pkexec 会以 root 进入这个模式。在启动 GTK/Flutter 之前恢复原用户
// 身份，只保留 CAP_NET_ADMIN/CAP_NET_RAW，然后 exec 正常应用。
void RunCapabilityBootstrap(int argc, char** argv) {
  if (argc < 2 || std::string(argv[1]) != "--vnt-capability-bootstrap") {
    return;
  }

  RedirectBootstrapLog();
  if (argc < 4) {
    std::fprintf(stderr,
                 "[vnt permission] Incomplete capability bootstrap request.\n");
    _exit(125);
  }
  uid_t uid = 0;
  uid_t pkexec_uid = 0;
  const char* pkexec_uid_value = std::getenv("PKEXEC_UID");
  if (!ParseUid(argv[2], &uid) || !ParseUid(pkexec_uid_value, &pkexec_uid) ||
      geteuid() != 0 || pkexec_uid != uid) {
    std::fprintf(stderr,
                 "[vnt permission] Refusing untrusted capability bootstrap.\n");
    _exit(125);
  }

  const passwd* user = getpwuid(uid);
  if (user == nullptr) {
    std::fprintf(stderr, "[vnt permission] %s\n",
                 LastError("getpwuid").c_str());
    _exit(125);
  }
  const gid_t gid = user->pw_gid;
  int group_count = 0;
  getgrouplist(user->pw_name, gid, nullptr, &group_count);
  std::vector<gid_t> groups(static_cast<size_t>(group_count));
  if (group_count > 0 &&
      getgrouplist(user->pw_name, gid, groups.data(), &group_count) < 0) {
    std::fprintf(stderr, "[vnt permission] %s\n",
                 LastError("getgrouplist").c_str());
    _exit(125);
  }

  int separator = 3;
  if (std::string(argv[separator]) == "--") {
    ++separator;
  }

  std::string error;
  if (prctl(PR_SET_KEEPCAPS, 1L) != 0) {
    error = LastError("PR_SET_KEEPCAPS");
  } else if (setgroups(groups.size(), groups.empty() ? nullptr : groups.data()) !=
             0) {
    error = LastError("setgroups");
  } else if (setgid(gid) != 0) {
    error = LastError("setgid");
  } else if (setuid(uid) != 0) {
    error = LastError("setuid");
  } else if (!SetNetworkCapabilities(&error)) {
    // error 已由 SetNetworkCapabilities 填充。
  }

  if (!error.empty()) {
    std::fprintf(stderr, "[vnt permission] %s\n", error.c_str());
    setenv("VNT_PERMISSION_BOOTSTRAP_ERROR", error.c_str(), 1);
    // 即使授权链失败也要以原用户身份打开 GUI，让用户能查看日志。
    // 如果前面的流程已完成 setuid，则不能也不需要再次 setgroups。
    if (geteuid() == 0) {
      if (setgroups(groups.size(),
                    groups.empty() ? nullptr : groups.data()) != 0 ||
          setgid(gid) != 0 || setuid(uid) != 0) {
        std::fprintf(stderr,
                     "[vnt permission] Refusing to start GUI because dropping "
                     "root privileges failed: %s\n",
                     std::strerror(errno));
        _exit(125);
      }
    }
    if (geteuid() != uid || getegid() != gid) {
      std::fprintf(stderr,
                   "[vnt permission] Refusing to start GUI with unexpected "
                   "identity uid=%u gid=%u.\n",
                   static_cast<unsigned int>(geteuid()),
                   static_cast<unsigned int>(getegid()));
      _exit(125);
    }
  } else {
    unsetenv("VNT_PERMISSION_BOOTSTRAP_ERROR");
    std::fprintf(stderr,
                 "[vnt permission] Temporary network capabilities granted "
                 "to uid=%u gid=%u.\n",
                 static_cast<unsigned int>(uid),
                 static_cast<unsigned int>(gid));
  }

  const std::string executable = ExecutablePath(argv[0]);
  std::vector<char*> app_arguments;
  app_arguments.push_back(const_cast<char*>(executable.c_str()));
  for (int index = separator; index < argc; ++index) {
    app_arguments.push_back(argv[index]);
  }
  app_arguments.push_back(nullptr);
  execv(executable.c_str(), app_arguments.data());
  std::fprintf(stderr, "[vnt permission] %s\n", LastError("execv").c_str());
  _exit(126);
}

// Replaces the native runner with pkexec before GTK and the Flutter engine are
// created. The same binary's bootstrap mode drops back to the original user
// while retaining only ambient network capabilities.
void RequestNetworkCapabilityBeforeFlutter(int argc, char** argv) {
  if (HasNetAdminCapability()) {
    return;
  }

  constexpr const char* kPkexec = "/usr/bin/pkexec";
  constexpr const char* kEnv = "/usr/bin/env";
  if (access(kPkexec, X_OK) != 0 || access(kEnv, X_OK) != 0) {
    // Dart will show a detailed diagnostic if the system lacks these tools.
    return;
  }

  const std::string executable = ExecutablePath(argc > 0 ? argv[0] : nullptr);
  const std::string helper_path =
      DirectoryName(executable) + "/lib/vnt_app/linux_cap_helpers";
  const char* current_path = std::getenv("PATH");

  RedirectBootstrapLog();
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
  arguments.emplace_back(executable);
  arguments.emplace_back("--vnt-capability-bootstrap");
  arguments.emplace_back(std::to_string(getuid()));
  arguments.emplace_back("--");
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
  RunCapabilityBootstrap(argc, argv);
  RequestNetworkCapabilityBeforeFlutter(argc, argv);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
