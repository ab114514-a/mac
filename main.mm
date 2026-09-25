
#import <Cocoa/Cocoa.h>
#include <iostream>
#include <sstream>
#include <string>
#include <mach/mach_time.h>
#include <vector>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_host.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <unistd.h>

struct ProcessInfo {
    int pid;
    std::string name;
    double cpuUsage;
    unsigned long long memory;
};

unsigned long long GetTotalMemory()
{
    int mib[2] = { CTL_HW, HW_MEMSIZE };
    unsigned long long mem = 0;
    size_t len = sizeof(mem);
    sysctl(mib, 2, &mem, &len, nullptr, 0);
    return mem;
}


unsigned long long GetUsedMemory()
{
    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    host_page_size(host, &pageSize);

    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64,
                          (host_info64_t)&vmStats, &count) != KERN_SUCCESS) {
        return 0;
    }

    unsigned long long active = vmStats.active_count * pageSize;
    unsigned long long inactive = vmStats.inactive_count * pageSize;
    unsigned long long wired = vmStats.wire_count * pageSize;
    unsigned long long compressed = vmStats.compressor_page_count * pageSize;

    return active + inactive + wired + compressed;
}

double GetCpuUsage(int pid)
{
    struct proc_taskinfo pti;
    int size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti));
    if (size <= 0) {
        return -1;
    }

    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }

    unsigned long long totalTime =
        pti.pti_total_user + pti.pti_total_system;

    double totalSeconds =
        (double)totalTime * timebase.numer / timebase.denom / 1e9;

    struct timeval bootTime;
    size_t bootLen = sizeof(bootTime);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    sysctl(mib, 2, &bootTime, &bootLen, nullptr, 0);

    struct timeval now;
    gettimeofday(&now, nullptr);

    double uptime =
        (now.tv_sec - bootTime.tv_sec) +
        (now.tv_usec - bootTime.tv_usec) / 1e6;

    if (uptime <= 0) return 0;

    // 单核百分比，再乘以核心数近似总 CPU 占用
    double cpu = totalSeconds / uptime * 100.0;

    int cpuCount = (int)[[NSProcessInfo processInfo] processorCount];
    cpu *= cpuCount;

    if (cpu < 0) cpu = 0;
    if (cpu > 100.0 * cpuCount) cpu = 100.0 * cpuCount;

    return cpu;
}

unsigned long long GetProcessMemory(int pid)
{
    struct proc_taskinfo pti;
    int size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti));
    if (size <= 0) {
        return 0;
    }
    return pti.pti_resident_size;
}

std::vector<ProcessInfo> GetAllProcesses()
{
    std::vector<ProcessInfo> result;

    int pidCount = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (pidCount <= 0) return result;

    std::vector<pid_t> pids(pidCount);
    pidCount = proc_listpids(PROC_ALL_PIDS, 0,
                             pids.data(),
                             (int)(pids.size() * sizeof(pid_t)));
    if (pidCount <= 0) return result;

    int count = pidCount / sizeof(pid_t);

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        char nameBuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int ret = proc_name(pid, nameBuf, sizeof(nameBuf));
        std::string name;
        if (ret > 0) {
            name = nameBuf;
        } else {
            name = "Unknown";
        }

        double cpu = GetCpuUsage(pid);
        if (cpu < 0) cpu = 0;

        unsigned long long mem = GetProcessMemory(pid);

        ProcessInfo info;
        info.pid = pid;
        info.name = name;
        info.cpuUsage = cpu;
        info.memory = mem;

        result.push_back(info);
    }

    return result;
}

std::string BuildReport()
{
    std::ostringstream oss;

    unsigned long long totalMem = GetTotalMemory();
    unsigned long long usedMem = GetUsedMemory();

    double memLoad = 0;
    if (totalMem > 0) {
        memLoad = (double)usedMem / totalMem * 100.0;
    }

    oss << "Total Memory: "
        << totalMem / 1024 / 1024
        << " MB\n";

    oss << "Memory Usage: "
        << (int)memLoad
        << "%\n";

    oss << "Process Token OK\n";

    oss << "----------------------------------------\n";

    auto processes = GetAllProcesses();

    int index = 0;
    for (const auto& p : processes) {
        index++;

        oss << "*" << index << " ";
        oss << "Process: " << p.name;
        oss << "// [PID: " << p.pid << " ]";
        oss << "//  CPU: " << p.cpuUsage << "%";
        oss << "//  Memory: "
            << p.memory / 1024 / 1024
            << " MB\n";
    }

    return oss.str();
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) NSTextView *textView;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{

    NSRect frame = NSMakeRect(100, 100, 900, 700);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];

    [self.window setTitle:@"Process Monitor"];

    NSScrollView *scrollView =
        [[NSScrollView alloc] initWithFrame:frame];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutoresizingMask:
        (NSViewWidthSizable | NSViewHeightSizable)];

    NSTextView *textView =
        [[NSTextView alloc] initWithFrame:frame];
    [textView setEditable:NO];
    [textView setFont:[NSFont fontWithName:@"Menlo" size:12]];
    [textView setAutoresizingMask:
        (NSViewWidthSizable | NSViewHeightSizable)];

    [scrollView setDocumentView:textView];
    [self.window setContentView:scrollView];

    self.textView = textView;

    std::string report = BuildReport();
    NSString *text =
        [NSString stringWithUTF8String:report.c_str()];

    [self.textView setString:text];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:
    (NSApplication *)sender
{
    return YES;
}

@end

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}